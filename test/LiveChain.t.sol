// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// تست یکپارچگی روی زنجیره زنده anvil (state پایدار start.sh)
/// قرارداد از قبل دیپلوی شده: proxy 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
/// ولت‌ها: حساب‌های پیش‌فرض anvil — کلیدها فقط برای تست لوکال
import "forge-std/Test.sol";
import "../contracts/RESNFT.sol";

contract LiveChainTest is Test {
    RESNFT res = RESNFT(payable(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512));

    uint256 constant ORACLE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // #0
    address constant ORACLE = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 constant ALICE_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;   // #1
    address constant ALICE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    modifier live() {
        // forge داخلی هم chainid=31337 میدهد؛ ملاک واقعی: کد قرارداد روی این آدرس هست؟
        if (address(res).code.length == 0) return; // بدون anvil زنده: تست‌ها بی‌صدا رد میشوند
        _;
    }

    function setUp() public {}

    /// ولت موجود (ALICE) میتواند ملکِ «برای فروش» را با قیمت صحیح بخرد
    function test_live_buy_with_existing_wallet() public live {
        // اوراکل ملک جدید میسازد، به نام خودش، 1 ETH، برای فروش
        vm.startPrank(ORACLE);
        res.addAsset(1 ether, ORACLE);
        uint256 id = res.assetCount() - 1;
        res.setForSale(id, true);
        vm.stopPrank();

        // ALICE ولت موجودِ واجد شرایط است
        assertTrue(res.isEligible(ALICE));
        deal(ALICE, 10 ether);

        uint256 oracleBefore = ORACLE.balance;
        vm.prank(ALICE);
        res.buy{value: 1 ether}(id);

        assertEq(res.ownerOf(id), ALICE);
        assertEq(ORACLE.balance - oracleBefore, 1 ether);
        (, bool stillSale, , , , , , , ) = res.getAsset(id);
        assertFalse(stillSale, "sold asset must leave sale");
    }

    /// همان ولت نمیتواند خارج از فروش بخرد (گیت forSale روی زنجیره زنده)
    function test_live_buy_rejected_when_not_for_sale() public live {
        vm.startPrank(ORACLE);
        res.addAsset(2 ether, ORACLE); // پیش‌فرض: خارج از فروش
        uint256 id = res.assetCount() - 1;
        vm.stopPrank();

        deal(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        res.buy{value: 2 ether}(id);
    }

    /// مالکیت دارایی‌های seed نباید توسط تست‌ها خراب شود — فقط خواندنی
    function test_live_seed_state_intact() public view live {
        assertGe(res.assetCount(), 4); // حداقل ۴ ملک seed دیپلوی
        // #0 و #1 نزد اوراکل، #2/#3 نزد ولت‌های دستی seed
        assertEq(res.ownerOf(0), ORACLE);
        assertEq(res.ownerOf(1), ORACLE);
        assertEq(res.balanceOf(ALICE), 0);
    }
}
