// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// تست ناوردای فدرال (داوری داخلی M8): همان stateful fuzzing فایل Invariant.t.sol، ولی با دو کشور
/// (۳۶۴ و ۲۷۶)، خرید فرامرزی، انجماد سراسری و محلی، تعلیق و بازگشت کشور، و توقف کل بازار.
/// گرداننده پیش از هر جابه‌جایی وضعیت را میسنجد؛ اگر جابه‌جایی‌ای موفق شود که قاعده‌ها باید ردش میکردند
/// (توقف بازار، حوزه‌ی معلق، فرستنده یا گیرنده‌ی منجمد/غیرمجاز)، شمارنده‌ی violations زیاد میشود.
/// مالک در این تست حساب استقرارکننده است و نقش شورا را بازی میکند (رأی‌گیری در Federation.t.sol آزموده شده).
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";

bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract FedHandler is Test {
    RESNFT public res;
    address public owner;
    uint16[2] public cc = [uint16(364), uint16(276)];
    address[2] public oracles;
    address[] public actors;      // actors[i] احرازشده در کشور cc[i % 2]
    uint256[] public roots;
    uint256 public violations;
    mapping(string => uint256) public calls; // فراخوانی‌های موفق هر عمل

    constructor(RESNFT r, address o, address[2] memory ors, address[] memory a) {
        res = r;
        owner = o;
        oracles = ors;
        actors = a;
    }

    function rootsLength() external view returns (uint256) { return roots.length; }

    function _actor(uint256 s) internal view returns (address) { return actors[s % actors.length]; }
    function _country(uint256 s) internal view returns (uint256) { return s % 2; }

    function _liveToken(uint256 s) internal view returns (bool ok, uint256 id, address o) {
        uint256 n = res.assetCount();
        if (n == 0) return (false, 0, address(0));
        id = s % n;
        try res.ownerOf(id) returns (address x) { return (true, id, x); } catch { return (false, id, address(0)); }
    }

    /// اولین توکن زنده‌ی آگهی‌شده از s به بعد (تا خرید واقعاً آزموده شود، نه فقط تلاش روی توکن تصادفی)
    function _listedToken(uint256 s) internal view returns (bool, uint256, address) {
        uint256 n = res.assetCount();
        for (uint256 i; i < n; ++i) {
            (bool ok, uint256 id, address o) = _liveToken(s + i);
            if (!ok) continue;
            (, bool forSale,,,,,,,) = res.getAsset(id);
            if (forSale) return (true, id, o);
        }
        return (false, 0, address(0));
    }

    /// اولین ملک کامل و تقسیم‌نشده از s به بعد
    function _wholeToken(uint256 s) internal view returns (bool, uint256, address) {
        uint256 n = res.assetCount();
        for (uint256 i; i < n; ++i) {
            (bool ok, uint256 id, address o) = _liveToken(s + i);
            if (!ok) continue;
            (,,, uint256 pct, bool isSplit,,,,) = res.getAsset(id);
            if (pct == 100 && !isSplit) return (true, id, o);
        }
        return (false, 0, address(0));
    }

    /// آیا جابه‌جایی توکن id از from به to طبق قواعد مجاز است؟
    function _moveAllowed(uint256 id, address from, address to) internal view returns (bool) {
        uint16 j = res.jurisdictionOf(id);
        return !res.paused() && !res.suspended(j) && res.canTrade(from, j) && res.canTrade(to, j);
    }

    function _ok(string memory action, bool allowed) internal {
        if (!allowed) violations++;
        calls[action]++;
    }

    // ---------------- بازار ----------------

    function mint(uint256 cs, uint256 actorSeed, uint96 price) external {
        uint256 k = _country(cs);
        address to = _actor(actorSeed);
        uint16 c = cc[k];
        bool allowed = !res.suspended(c) && res.canTrade(to, c);
        vm.prank(oracles[k]);
        try res.addAsset(bound(price, 1, 1e24), to, CASE_REF) returns (uint256 id) {
            roots.push(id);
            _ok("mint", allowed);
        } catch {}
    }

    function list(uint256 s, uint96 price) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        if (!ok) return;
        (,,, uint256 pct,,,,,) = res.getAsset(id);
        uint256 p = bound(price, 1, 1e24) * pct / 100 + 1;
        vm.startPrank(o);
        try res.changePrice(id, p) {} catch {}
        try res.setForSale(id, true) { calls["list"]++; } catch {}
        vm.stopPrank();
    }

    function buy(uint256 s, uint256 buyerSeed) external {
        (bool ok, uint256 id, address o) = _listedToken(s);
        if (!ok) return;
        address b = _actor(buyerSeed);
        if (b == o) return;
        (uint256 price, bool forSale,,,,,,,) = res.getAsset(id);
        if (!forSale) return;
        bool allowed = _moveAllowed(id, o, b);
        vm.deal(b, price);
        vm.prank(b);
        try res.buy{value: price}(id) { _ok("buy", allowed); } catch {}
    }

    function transfer(uint256 s, uint256 toSeed) external {
        (bool ok, uint256 id, address o) = _liveToken(s);
        if (!ok) return;
        address to = _actor(toSeed);
        if (to == o) return;
        bool allowed = _moveAllowed(id, o, to);
        vm.prank(o);
        try res.transferFrom(o, to, id) { _ok("transfer", allowed); } catch {}
    }

    function split(uint256 s, uint8 parts, uint256 toSeed) external {
        (bool ok, uint256 id, address o) = _wholeToken(s);
        if (!ok) return;
        uint256 k = bound(parts, 2, 20);
        uint256[] memory p = new uint256[](k);
        address[] memory to = new address[](k);
        uint256 left = 100;
        bool allowed = true;
        for (uint256 i; i < k; ++i) {
            p[i] = i == k - 1 ? left : 100 / k;
            left -= p[i];
            to[i] = _actor(toSeed + i % 2); // دو گیرنده، تا تقسیم و ادغام زیر انجماد هم رخ دهند
            allowed = allowed && _moveAllowed(id, o, to[i]);
        }
        vm.prank(o);
        try res.split(id, p, to) { _ok("split", allowed); } catch {}
    }

    function gatherAndMerge(uint256 rootSeed, uint256 actorSeed) external {
        uint256 root;
        uint256[] memory kids;
        for (uint256 i; i < roots.length && kids.length == 0; ++i) {
            root = roots[(rootSeed + i) % roots.length];
            kids = res.childrenOf(root);
        }
        if (kids.length == 0) return;
        address who = _actor(actorSeed);
        for (uint256 i; i < kids.length; ++i) {
            address o = res.ownerOf(kids[i]);
            if (o == who) continue;
            bool allowed = _moveAllowed(kids[i], o, who);
            vm.prank(o);
            try res.transferFrom(o, who, kids[i]) { _ok("transfer", allowed); } catch { return; }
        }
        bool mergeAllowed = _moveAllowed(root, who, who);
        vm.prank(who);
        try res.merge(root) { _ok("merge", mergeAllowed); } catch {}
    }

    function reissue(uint256 s, uint256 toSeed) external {
        (bool ok, uint256 id,) = _liveToken(s);
        if (!ok) return;
        uint16 j = res.jurisdictionOf(id);
        address to = _actor(toSeed);
        bool allowed = !res.suspended(j) && res.canTrade(to, j);
        vm.prank(res.oracleOf(j));
        try res.reissueAsset(id, to, CASE_REF) { _ok("reissue", allowed); } catch {}
    }

    // ---------------- اجرای حکم و حاکمیت ----------------

    function freezeLocal(uint256 cs, uint256 actorSeed, uint8 r) external {
        bool frozen = r % 10 == 7; // نه ۰: fuzzer مقدار ۰ را زیاد میسازد
        uint256 k = _country(cs);
        vm.prank(oracles[k]);
        try res.freezeLocal(_actor(actorSeed), frozen, CASE_REF) { calls["freezeLocal"]++; } catch {}
    }

    /// انجماد سراسری و آزادسازی، فقط توسط کشور احرازکننده
    function freezeGlobal(uint256 actorSeed, uint8 r) external {
        bool frozen = r % 10 == 7; // نه ۰: fuzzer مقدار ۰ را زیاد میسازد // اجرای حکم در ۱۰٪ فراخوانی‌ها، تا بازار هم فعال بماند
        address a = _actor(actorSeed);
        vm.startPrank(oracles[actorSeed % actors.length % 2]);
        if (frozen) {
            try res.removeFromEligibleList(a, CASE_REF) { calls["freezeGlobal"]++; } catch {}
        } else {
            try res.addToEligibleList(a, CASE_REF) { calls["unfreezeGlobal"]++; } catch {}
        }
        vm.stopPrank();
    }

    /// تعلیق کشور (شورا) و بازگشت با درخواست دوباره‌ی همان آدرس و تأیید شورا
    function suspendCountry(uint256 cs, uint8 r) external {
        bool suspendIt = r % 10 == 7; // نه ۰: fuzzer مقدار ۰ را زیاد میسازد
        uint256 k = _country(cs);
        if (suspendIt) {
            vm.prank(owner);
            try res.suspend(cc[k]) { calls["suspend"]++; } catch {}
        } else {
            vm.prank(oracles[k]);
            res.requestOracle(cc[k], address(0));
            vm.prank(owner);
            try res.approveOracle(cc[k], oracles[k]) { calls["resume"]++; } catch {}
        }
    }

    function pause(uint8 r) external {
        bool p = r % 10 == 7; // نه ۰: fuzzer مقدار ۰ را زیاد میسازد
        vm.prank(owner);
        if (p) { try res.pause() { calls["pause"]++; } catch {} }
        else { try res.unpause() { calls["unpause"]++; } catch {} }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
contract InvariantFederationTest is Test {
    RESNFT res;
    FedHandler handler;
    address deployer = makeAddr("deployer");

    function setUp() public {
        address[2] memory ors = [makeAddr("oracleIR"), makeAddr("oracleDE")];
        vm.prank(deployer);
        RESNFT impl = new RESNFT();
        vm.prank(deployer);
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (uint16(364)))))));
        vm.prank(ors[0]); res.requestOracle(364, address(0));
        vm.prank(ors[1]); res.requestOracle(276, address(0));
        vm.startPrank(deployer);
        res.approveOracle(364, ors[0]);
        res.approveOracle(276, ors[1]);
        vm.stopPrank();
        address[] memory actors = new address[](6);
        for (uint256 i; i < 6; ++i) {
            actors[i] = makeAddr(string.concat("fedActor", vm.toString(i)));
            vm.prank(ors[i % 2]);
            res.addToEligibleList(actors[i], CASE_REF);
        }
        handler = new FedHandler(res, deployer, ors, actors);
        targetContract(address(handler));
    }

    function invariant_ownership_sums_to_100() public view {
        for (uint256 i; i < handler.rootsLength(); ++i) {
            uint256 root = handler.roots(i);
            uint256[] memory kids = res.childrenOf(root);
            if (_live(root)) {
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

    /// هر سهم در حوزه‌ی قضایی ملک مادرش میماند
    function invariant_shares_keep_jurisdiction() public view {
        for (uint256 i; i < handler.rootsLength(); ++i) {
            uint256 root = handler.roots(i);
            uint256[] memory kids = res.childrenOf(root);
            for (uint256 j; j < kids.length; ++j) {
                assertEq(res.jurisdictionOf(kids[j]), res.jurisdictionOf(root), "share left parent's jurisdiction");
            }
        }
    }

    /// هیچ جابه‌جایی‌ای برخلاف توقف، تعلیق یا انجماد موفق نشده است
    function invariant_no_forbidden_move() public view {
        assertEq(handler.violations(), 0, "forbidden move succeeded");
    }

    function invariant_no_funds_stuck() public view {
        assertEq(address(res).balance, 0);
    }

    function invariant_listing_has_price() public view {
        for (uint256 id; id < res.assetCount(); ++id) {
            if (!_live(id)) continue;
            (uint256 price, bool forSale,,,,,,,) = res.getAsset(id);
            if (forSale) assertGt(price, 0);
        }
    }

    /// گزارش تعداد فراخوانی‌های موفق هر عمل (برای مقاله)
    function afterInvariant() external view {
        string[13] memory a = ["mint", "list", "buy", "transfer", "split", "merge", "reissue",
            "freezeLocal", "freezeGlobal", "unfreezeGlobal", "suspend", "resume", "pause"];
        string memory s = "CALLS";
        for (uint256 i; i < a.length; ++i) {
            s = string.concat(s, ",", a[i], "=", vm.toString(handler.calls(a[i])));
        }
        console.log(s);
    }

    function _live(uint256 id) internal view returns (bool) {
        try res.ownerOf(id) returns (address) { return true; } catch { return false; }
    }
}
