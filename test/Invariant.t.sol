// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// تست ناوردا (stateful fuzzing) — داور ۲، بند ۷: مجموع مالکیت هر ملک همیشه ۱۰۰٪، بدون ادعای تکراری،
/// والد ساقط‌شده زنده نمیشود مگر با merge کامل، پولی در قرارداد گیر نمیکند، آگهی فروش بی‌قیمت وجود ندارد.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";

// مرجع پرونده ثبتی آزمایشی (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract Handler is Test {
    RESNFT public res;
    address public oracle;
    address[] public actors;
    uint256[] public roots; // ملک‌های ضرب‌شده توسط اوراکل

    constructor(RESNFT r, address o, address[] memory a) {
        res = r;
        oracle = o;
        actors = a;
    }

    function rootsLength() external view returns (uint256) { return roots.length; }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }

    function _liveToken(uint256 s) internal view returns (bool ok, uint256 id, address owner) {
        uint256 n = res.assetCount();
        if (n == 0) return (false, 0, address(0));
        id = s % n;
        try res.ownerOf(id) returns (address o) { return (true, id, o); } catch { return (false, id, address(0)); }
    }

    function mint(uint256 actorSeed, uint96 price) external {
        price = uint96(bound(price, 1, 100 ether));
        vm.prank(oracle);
        roots.push(res.addAsset(price, _actor(actorSeed), CASE_REF));
    }

    function list(uint256 s, uint96 price) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        if (!ok) return;
        price = uint96(bound(price, 1, 100 ether));
        vm.startPrank(o);
        res.changePrice(id, price);
        res.setForSale(id, true);
        vm.stopPrank();
    }

    function discount(uint256 s, uint256 buyerSeed, uint96 price) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        if (!ok) return;
        (uint256 p,,,,,,,,) = res.getAsset(id);
        if (p < 2) return;
        vm.prank(o);
        res.setCustomPrice(id, _actor(buyerSeed), bound(price, 1, p - 1));
    }

    function buy(uint256 s, uint256 buyerSeed) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        address buyer = _actor(buyerSeed);
        if (!ok || buyer == o) return;
        (, bool forSale,,,,,,,) = res.getAsset(id);
        if (!forSale) return;
        uint256 price = res.priceFor(id, buyer);
        vm.deal(buyer, price);
        vm.prank(buyer);
        res.buy{value: price}(id);
    }

    function transfer(uint256 s, uint256 toSeed) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        address to = _actor(toSeed);
        if (!ok || to == o) return;
        vm.prank(o);
        res.transferFrom(o, to, id);
    }

    function split(uint256 s, uint8 parts, uint256 toSeed) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        if (!ok) return;
        (,,, uint256 pct, bool isSplit,,,,) = res.getAsset(id);
        if (pct != 100 || isSplit) return;
        uint256 k = bound(parts, 2, 20);
        uint256[] memory p = new uint256[](k);
        address[] memory to = new address[](k);
        uint256 left = 100;
        for (uint256 i; i < k; ++i) {
            p[i] = i == k - 1 ? left : 100 / k;
            left -= p[i];
            to[i] = _actor(toSeed + i);
        }
        vm.prank(o);
        res.split(id, p, to);
    }

    function gatherAndMerge(uint256 rootSeed, uint256 actorSeed) external {
        if (roots.length == 0) return;
        uint256 root = roots[rootSeed % roots.length];
        uint256[] memory kids = res.childrenOf(root);
        if (kids.length == 0) return;
        address who = _actor(actorSeed);
        for (uint256 i; i < kids.length; ++i) {
            address o = res.ownerOf(kids[i]);
            if (o != who) {
                vm.prank(o);
                res.transferFrom(o, who, kids[i]);
            }
        }
        vm.prank(who);
        res.merge(root);
    }

    function reissue(uint256 s, uint256 toSeed) external {
        (bool ok, uint256 id,) = _liveToken(s);
        if (!ok) return;
        vm.prank(oracle);
        res.reissueAsset(id, _actor(toSeed), CASE_REF);
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
contract InvariantTest is Test {
    RESNFT res;
    Handler handler;
    address oracle = makeAddr("oracle");

    function setUp() public {
        vm.startPrank(oracle);
        RESNFT impl = new RESNFT();
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (uint16(364)))))));
        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            res.addToEligibleList(actors[i], CASE_REF);
        }
        vm.stopPrank();
        handler = new Handler(res, oracle, actors);
        targetContract(address(handler));
    }

    /// هر ملک: یا والد زنده است و هیچ سهمی ندارد، یا والد ساقط است و سهم‌های زنده دقیقاً ۱۰۰٪ اند
    function invariant_ownership_sums_to_100() public view {
        for (uint256 i; i < handler.rootsLength(); ++i) {
            uint256 root = handler.roots(i);
            uint256[] memory kids = res.childrenOf(root);
            bool rootLive = _live(root);
            if (rootLive) {
                assertEq(kids.length, 0, "live parent with live shares");
            } else {
                uint256 sum;
                for (uint256 j; j < kids.length; ++j) {
                    assertTrue(_live(kids[j]), "share missing");
                    (,,, uint256 p,,,,,) = res.getAsset(kids[j]);
                    sum += p;
                }
                assertEq(sum, 100, "shares must sum to 100");
            }
        }
    }

    function invariant_no_funds_stuck() public view {
        assertEq(address(res).balance, 0);
    }

    function invariant_listing_has_price_and_owner_eligible() public view {
        for (uint256 id; id < res.assetCount(); ++id) {
            if (!_live(id)) continue;
            (uint256 price, bool forSale,,,, address o,,,) = res.getAsset(id);
            if (forSale) assertGt(price, 0);
            assertTrue(res.isEligible(o));
        }
    }

    function _live(uint256 id) internal view returns (bool) {
        try res.ownerOf(id) returns (address) { return true; } catch { return false; }
    }
}
