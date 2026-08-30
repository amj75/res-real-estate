// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";

contract RESNFTTest is Test {
    RESNFT res;
    address oracle = makeAddr("oracle");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.prank(oracle);
        RESNFT impl = new RESNFT();
        vm.prank(oracle);
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, ())))));
        for (uint256 i; i < 3; ++i) {
            address[] memory who = new address[](1);
            who[0] = i == 0 ? seller : buyer;
            vm.prank(oracle);
            res.addToEligibleList(who[0]);
        }
        // oracle مالک قرارداد است چون خودش دیپلوی کرده
        assertEq(res.oracleAddress(), oracle);
    }

    /// UUPS: ارتقا توسط مالک + حفظ کامل state
    function test_upgrade_keeps_state() public {
        uint256 id = _mintFor(seller, 1 ether);
        assertEq(res.assetCount(), 1);

        // غیرمالک نمیتواند ارتقا دهد
        RESNFT impl2 = new RESNFT();
        vm.prank(seller);
        vm.expectRevert();
        res.upgradeToAndCall(address(impl2), "");

        // مالک ارتقا میدهد — همه داده‌ها سر جایشان
        vm.prank(oracle);
        res.upgradeToAndCall(address(impl2), "");
        assertEq(res.ownerOf(id), seller);
        assertEq(res.assetCount(), 1);
        assertTrue(res.isEligible(buyer));
    }

    function test_mint_and_buy() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(seller);
        res.setForSale(id, true); // مالک اجازه فروش میدهد

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        res.buy{value: 1 ether}(id);

        assertEq(res.ownerOf(id), buyer);
        assertEq(res.renterOf(id), buyer);
        assertEq(seller.balance, 1 ether);
        // قیمت بعد از فروش صفر شده (نه برای فروش تا خریدار قیمت بگذارد)
        (uint256 price,,,,,,,,) = res.getAsset(id);
        assertEq(price, 0);
    }

    /// ملک بدون forSale قابل خرید نیست حتی با قیمت
    function test_not_for_sale_rejected() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert("not for sale");
        res.buy{value: 1 ether}(id);
    }

    /// قیمت اختصاصی تخفیف‌دار فقط برای خریدار مشخص اعمال میشود
    function test_custom_price_discount() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.startPrank(seller);
        res.setForSale(id, true);
        res.setCustomPrice(id, buyer, 0.7 ether);
        vm.stopPrank();

        // خریدار دیگر قیمت عمومی میپردازد
        address other = makeAddr("other");
        vm.prank(res.oracleAddress());
        res.addToEligibleList(other);
        vm.deal(other, 1 ether);
        vm.prank(other);
        res.buy{value: 1 ether}(id);

        assertEq(other.balance, 0);
    }

    /// انتقال مستقیم بدون پرداخت — ثبت معامله خارج از زنجیره
    function test_transfer_direct() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(seller);
        res.transferDirect(id, buyer);
        assertEq(res.ownerOf(id), buyer);
        assertEq(res.renterOf(id), buyer);
    }

    function test_transfer_direct_rejects_not_owner() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert("not owner");
        res.transferDirect(id, buyer);
    }

    function test_buy_rejects_wrong_value() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(seller);
        res.setForSale(id, true);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert("wrong value");
        res.buy{value: 0.5 ether}(id);
    }

    function test_buy_rejects_not_eligible() public {
        uint256 id = _mintFor(seller, 1 ether);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert("buyer not eligible");
        res.buy{value: 1 ether}(id);
    }

    function test_split_then_merge() public {
        uint256 id = _mintFor(seller, 2 ether);
        address childA = makeAddr("childA");
        address childB = makeAddr("childB");
        vm.prank(oracle);
        res.addToEligibleList(childA);
        vm.prank(oracle);
        res.addToEligibleList(childB);

        uint256[] memory percents = new uint256[](2);
        percents[0] = 60;
        percents[1] = 40;
        address[] memory to = new address[](2);
        to[0] = childA;
        to[1] = childB;

        vm.prank(seller);
        uint256[] memory kids = res.split(id, percents, to);

        assertEq(kids.length, 2);
        vm.expectRevert(); // والد ساقط شده
        res.ownerOf(id);

        // فقط وقتی همه فرزندان نزد یک نفر باشند merge ممکن است
        vm.startPrank(childB);
        vm.expectRevert("caller does not own all children");
        res.merge(id);
        vm.stopPrank();

        // جمع‌آوری فرزندان: childB فرزند دومش را به childA منتقل میکند
        vm.prank(childB);
        res.approve(childA, kids[1]);
        vm.prank(childA);
        res.transferFrom(childB, childA, kids[1]);

        vm.prank(childA);
        res.merge(id);
        assertEq(res.ownerOf(id), childA);
        (,,,, bool splitFlag,,,,) = res.getAsset(id);
        assertFalse(splitFlag);
    }

    function test_split_percent_validation() public {
        uint256 id = _mintFor(seller, 2 ether);
        uint256[] memory percents = new uint256[](2);
        percents[0] = 50;
        percents[1] = 30; // جمع = 80 ≠ 100
        address[] memory to = new address[](2);
        to[0] = buyer;
        to[1] = makeAddr("x");
        vm.prank(oracle);
        res.addToEligibleList(to[1]);
        vm.prank(seller);
        vm.expectRevert("percents must sum to parent");
        res.split(id, percents, to);
    }

    function test_change_price_only_owner() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert("not owner");
        res.changePrice(id, 5 ether);
        vm.prank(seller);
        res.changePrice(id, 3 ether);
        (uint256 price,,,,,,,,) = res.getAsset(id);
        assertEq(price, 3 ether);
    }

    function test_zero_price_rejected() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert("price must be > 0");
        res.changePrice(id, 0);
    }

    function test_renter_only_oracle() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert("only oracle");
        res.changeRenter(id, buyer);
        vm.prank(oracle);
        res.changeRenter(id, buyer);
        assertEq(res.renterOf(id), buyer);
    }

    function test_addAsset_only_oracle() public {
        vm.prank(seller);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, seller);
    }

    // ---------- helper ----------
    function _mintFor(address to, uint256 price) internal returns (uint256) {
        vm.prank(oracle);
        return res.addAsset(price, to);
    }

        // ---------- v3: گیت انتقال، اجاره زمانی، reissue تمیز ----------
    
    /// سرقت مسیر ERC721 بسته است: transferFrom به ولت غیرمجاز revert میشود
        function test_transfer_to_ineligible_reverts() public {
            uint256 id = _mintFor(seller, 1 ether);
            address thief = makeAddr("thief"); // غیرمجاز
            vm.prank(seller);
            vm.expectRevert("receiver not eligible");
            res.transferFrom(seller, thief, id);
        }
    
    /// approve هم راه فرار نیست: spender مجاز نمیتواند به غیرمجاز بفرستد
        function test_approved_spender_cannot_send_to_ineligible() public {
            uint256 id = _mintFor(seller, 1 ether);
            address helper = makeAddr("helper");
            vm.prank(seller);
            res.approve(helper, id);
            vm.prank(helper);
            vm.expectRevert("receiver not eligible");
            res.transferFrom(seller, makeAddr("thief"), id);
        }
    
    /// انتقال به ولت واجد شرایط از طریق ERC721 آزاد است (رفتار استاندارد حفظ شده)
        function test_transfer_to_eligible_ok() public {
            uint256 id = _mintFor(seller, 1 ether);
            vm.prank(seller);
            res.transferFrom(seller, buyer, id);
            assertEq(res.ownerOf(id), buyer);
        }
    
    /// اجاره: اوراکل ثبت میکند؛ انقضا باید بعد از شروع باشد؛ مستأجر باید مجاز باشد
        function test_set_rent() public {
            uint256 id = _mintFor(seller, 1 ether);
            uint64 start = 1_700_000_000;
            uint64 expiry = start + 30 days;
            vm.prank(oracle);
            res.setRent(id, buyer, start, expiry);
    
            (,,,,,, address renter, uint64 rs, uint64 re) = res.getAsset(id);
            assertEq(renter, buyer);
            assertEq(rs, start);
            assertEq(re, expiry);
    
            // انقضا قبل از شروع → رد
            vm.prank(oracle);
            vm.expectRevert("expiry must be after start");
            res.setRent(id, buyer, expiry, start);
    
            // مستأجر غیرمجاز → رد
            vm.prank(oracle);
            vm.expectRevert("renter not eligible");
            res.setRent(id, makeAddr("x"), start, expiry);
        }
    
    /// لغو اجاره با renter=0 — دوره هم پاک میشود
        function test_set_rent_cancel() public {
            uint256 id = _mintFor(seller, 1 ether);
            vm.startPrank(oracle);
            res.setRent(id, buyer, 1_700_000_000, 1_700_000_000 + 1 days);
            res.setRent(id, address(0), 0, 0);
            vm.stopPrank();
            (,,,,,, address renter,,) = res.getAsset(id);
            assertEq(renter, address(0));
        }
    
    /// تغییر مالکیت دوره اجاره قبلی را بیاعتبار میکند (در _update)
        function test_transfer_clears_rent_period() public {
            uint256 id = _mintFor(seller, 1 ether);
            vm.prank(oracle);
            res.setRent(id, seller, 1_700_000_000, 1_700_000_000 + 1 days);
            vm.prank(seller);
            res.transferFrom(seller, buyer, id);
            (,,,,,,, uint64 rs,) = res.getAsset(id);
            assertEq(rs, 0, "rent period must clear on transfer");
        }
    
    /// reissue وضعیت فروش قدیمی را کامل پاک میکند
        function test_reissue_clean_state() public {
            uint256 id = _mintFor(seller, 1 ether);
            vm.startPrank(seller);
            res.setForSale(id, true);
            res.changePrice(id, 5 ether); // قیمت را عوض میکنیم تا مشخص شود مال چه کسیست
            vm.stopPrank();
    
            // به ولت دیگرِ واجد شرایط بازتخصیص
            address newOwner = makeAddr("newOwner");
            vm.prank(oracle);
            res.addToEligibleList(newOwner);
            vm.prank(oracle);
            res.reissueAsset(id, newOwner);
    
            assertEq(res.ownerOf(id), newOwner);
            (uint256 price, bool forSale,,,,,,, ) = res.getAsset(id);
            assertEq(price, 0);
            assertFalse(forSale);
    }

    // ---------- امنیت: reentrancy عملی + initialize + self-buy ----------

    /// حمله reentrancy واقعی: مهاجم خودش فروشنده است و در هنگام دریافت پول به buy دوباره
    /// حمله میکند. قرارداد سالم باید بگذارد پول را بگیرد ولی خرید دوم را رد کند
    /// (nonReentrant + effects قبل از interactions)
    function test_buy_reentrancy_blocked() public {
        Attacker attacker = new Attacker(res);
        address legitBuyer = makeAddr("legitBuyer");
        vm.startPrank(oracle);
        res.addToEligibleList(address(attacker));   // مهاجم هم باید مجاز باشد تا mint شود
        res.addToEligibleList(address(legitBuyer));
        vm.stopPrank();

        // توکن مستقیم به قرارداد مهاجم (فروشنده آینده)
        uint256 id = _mintFor(address(attacker), 1 ether);
        attacker.setForSale(id);
        vm.deal(legitBuyer, 10 ether);

        // خریدار مشروع میخرد → پول به receiveِ مهاجم میرسد → او reenter میکند
        vm.prank(legitBuyer);
        res.buy{value: 1 ether}(id);

        // buy دوم داخل receive باید revert کرده باشد (nonReentrant) — else the tx would have reverted
        assertEq(res.ownerOf(id), legitBuyer);
        assertEq(attacker.buyAttempts(), 1, "reentrancy call attempted exactly once");
        assertEq(address(attacker).balance, 1 ether, "seller got paid once, no double-spend");
    }

    /// خرید خود-دارایی مسدود است
    function test_buy_own_asset_rejected() public {
        uint256 id = _mintFor(seller, 1 ether);
        vm.startPrank(seller);
        res.setForSale(id, true);
        vm.deal(seller, 1 ether);   // seller اتر لازم برای پیوست به tx دارد
        vm.expectRevert(bytes("own asset"));
        res.buy{value: 1 ether}(id);
        vm.stopPrank();
    }
    /// initialize دوباره روی پروکسی نمیتواند اجرا شود (initializer guard)
    function test_reinitialize_blocked() public {
        vm.expectRevert();
        res.initialize();
    }
}

/// قرارداد مهاجم: در receive دوباره buy صدا میزند
interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

contract Attacker is IERC721Receiver {
    RESNFT immutable res;
    uint256 public buyAttempts;
    uint256 public target;

    constructor(RESNFT r) { res = r; }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setForSale(uint256 assetId) external {
        res.setForSale(assetId, true);
    }

    function attack(uint256 assetId, address buyer) external payable {
        target = assetId;
        res.buy{value: 1 ether}(assetId); // خرید اول — اینجا ما «خریدار» هستیم؛ باید توکن قبلاً به ما فروخته شده باشد
    }

    // فروشنده‌ای که در حین خریدِ توکنش reenter میکند
    receive() external payable {
        if (msg.sender == address(res) && buyAttempts == 0) {
            buyAttempts++;
            // حمله مجدد: buy همان توکنِ فروخته‌شده — باید revert شود (nonReentrant)
            (bool ok, ) = address(res).call{value: 1 ether}(
                abi.encodeWithSelector(res.buy.selector, target)
            );
            require(!ok, "reentrancy must be blocked");
        }
    }
}
