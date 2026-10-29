// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// سناریوهای خصمانه و شکست (داور ۲، بند ۱۸): ضرب غیرمجاز، انتقال غیرمجاز، لو رفتن کلید اوراکل،
/// تقسیم نامعتبر، خرید همزمان، front-running، فروشنده مخرب، بازیابی ولت، توکن ساقط‌شده، ولت غیرمجاز،
/// replay امضا، و رگرسیون سه باگ نسخه v3.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../contracts/RESNFT.sol";
import "./legacy/RESNFTv3.sol";
import "./helpers/MultisigOracle.sol";

// مرجع پرونده ثبتی آزمایشی (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract AdversarialTest is Test {
    RESNFT res;
    address owner = makeAddr("owner");   // در استقرار واقعی: timelock/multisig
    address o1 = makeAddr("oracle1");
    address o2 = makeAddr("oracle2");
    address o3 = makeAddr("oracle3");
    address a = makeAddr("alice");
    address b = makeAddr("bob");
    address x = makeAddr("mallory");
    uint16 constant IR = 364;

    function setUp() public {
        vm.startPrank(owner);
        RESNFT impl = new RESNFT();
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (IR))))));
        vm.stopPrank();
        _appoint(o1);                // مالک و اوراکل از هم جدا
        vm.startPrank(o1);
        res.addToEligibleList(a, CASE_REF);
        res.addToEligibleList(b, CASE_REF);
        res.addToEligibleList(x, CASE_REF);
        vm.stopPrank();
    }

    function _mint(address to, uint256 price) internal returns (uint256) {
        vm.prank(o1);
        return res.addAsset(price, to, CASE_REF);
    }

    /// آدرس جدید درخواست میدهد، مالک (در استقرار واقعی OracleCouncil با ۲/۳) تأیید میکند
    function _appoint(address oracle) internal {
        vm.prank(oracle);
        res.requestOracle(IR, address(0));
        vm.prank(owner);
        res.approveOracle(IR, oracle);
    }

    function _list(address who, uint256 id) internal {
        vm.prank(who);
        res.setForSale(id, true);
    }

    /// اوراکل = multisig ۲-از-۳ امضاکنندگان مرجع ثبت (o1, o2, o3)
    function _multisigOracle() internal returns (MultisigOracle ms) {
        address[] memory s = new address[](3);
        s[0] = o1; s[1] = o2; s[2] = o3;
        ms = new MultisigOracle(s, 2);
        _appoint(address(ms)); // درخواست = یک تراکنش Safe در استقرار واقعی
    }

    // ---------------- رگرسیون باگ‌های v3 ----------------

    /// v3: آگهی فروش بعد از transferFrom باقی میماند و شخص ثالث ملک گیرنده را میخرید
    function test_regression_listing_cleared_on_transfer() public {
        uint256 id = _mint(a, 10 ether);
        _list(a, id);
        vm.prank(a);
        res.transferFrom(a, b, id);
        vm.deal(x, 10 ether);
        vm.prank(x);
        vm.expectRevert("not for sale");
        res.buy{value: 10 ether}(id);
        assertEq(res.renterOf(id), b);
    }

    /// v3: تخفیف مالک قبلی بعد از فروش باقی میماند (ملک ۲۰ اتری با ۱ wei خریده میشد)
    function test_regression_custom_price_cleared_on_sale() public {
        uint256 id = _mint(a, 10 ether);
        vm.startPrank(a);
        res.setForSale(id, true);
        res.setCustomPrice(id, x, 1 wei);
        vm.stopPrank();
        vm.deal(b, 10 ether);
        vm.prank(b);
        res.buy{value: 10 ether}(id);

        vm.startPrank(b);
        res.changePrice(id, 20 ether);
        res.setForSale(id, true);
        vm.stopPrank();
        assertEq(res.customPrice(id, x), 0);
        vm.deal(x, 1);
        vm.prank(x);
        vm.expectRevert("wrong value");
        res.buy{value: 1 wei}(id);
    }

    /// v3: reissue روی یک سهم آن را ۱۰۰٪ میکرد → مجموع مالکیت > ۱۰۰٪
    function test_regression_reissue_child_keeps_share() public {
        uint256 id = _mint(a, 10 ether);
        uint256[] memory kids = _split(a, id, _arr(60, 40), _addrs(a, b));
        vm.prank(o1);
        res.reissueAsset(kids[1], x, CASE_REF);
        (,, uint256 parent, uint256 pct,,,,,) = res.getAsset(kids[1]);
        assertEq(parent, id);
        assertEq(pct, 40);
        assertEq(res.ownerOf(kids[1]), x);
    }

    /// v3: فرزندان ملک #0 هم parent=0 داشتند و دوباره قابل تقسیم بودند (ادغام والد #0 را میشکست)
    function test_regression_child_of_asset_zero_not_splittable() public {
        uint256 id = _mint(a, 1 ether);
        assertEq(id, 0);
        uint256[] memory kids = _split(a, id, _arr(60, 40), _addrs(a, a));
        vm.prank(a);
        vm.expectRevert("already split / child");
        res.split(kids[0], _arr(30, 30), _addrs(a, b));
    }

    /// اگر مالک قیمت عمومی را زیر تخفیف بیاورد، خریدار تخفیفی بیشتر نمیپردازد
    function test_custom_price_never_above_public() public {
        uint256 id = _mint(a, 10 ether);
        vm.startPrank(a);
        res.setCustomPrice(id, b, 8 ether);
        res.changePrice(id, 5 ether);
        res.setForSale(id, true);
        vm.stopPrank();
        assertEq(res.priceFor(id, b), 5 ether);
    }

    // ---------------- کنترل دسترسی ----------------

    function test_unauthorized_mint_reverts() public {
        vm.prank(x);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, x, CASE_REF);
        // مالک قرارداد هم اوراکل نیست
        vm.prank(owner);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, a, CASE_REF);
    }

    function test_unauthorized_governance_reverts() public {
        RESNFT impl2 = new RESNFT();
        vm.startPrank(o1); // اوراکل اختیار حاکمیتی ندارد
        vm.expectRevert();
        res.approveOracle(IR, o1);
        vm.expectRevert();
        res.suspend(IR);
        vm.expectRevert();
        res.upgradeToAndCall(address(impl2), "");
        vm.expectRevert();
        res.unpause();
        vm.expectRevert(); // اوراکل یک کشور نمیتواند کل بازار را متوقف کند
        res.pause();
        vm.stopPrank();
    }

    function test_unauthorized_transfer_reverts() public {
        uint256 id = _mint(a, 1 ether);
        vm.prank(x);
        vm.expectRevert(); // ERC721InsufficientApproval
        res.transferFrom(a, x, id);
        vm.prank(x);
        vm.expectRevert("not owner");
        res.transferDirect(id, x);
    }

    function test_non_eligible_cannot_act() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert("buyer not eligible");
        res.buy{value: 1 ether}(id);
        vm.prank(a);
        vm.expectRevert("receiver not eligible");
        res.safeTransferFrom(a, stranger, id);
        vm.prank(o1);
        vm.expectRevert("owner not eligible");
        res.addAsset(1 ether, stranger, CASE_REF);
    }

    // ---------------- اوراکل multisig و لو رفتن کلید ----------------

    /// ضرب با multisig ۲-از-۳: یک امضا کافی نیست، دومی اجرا میکند
    function test_multisig_oracle_2_of_3_mint() public {
        MultisigOracle ms = _multisigOracle();
        vm.prank(o1); // امضاکننده مستقیم دیگر اوراکل نیست
        vm.expectRevert("only oracle");
        res.addAsset(5 ether, a, CASE_REF);

        vm.prank(o1);
        uint256 cid = ms.submit(address(res), abi.encodeCall(RESNFT.addAsset, (5 ether, a, CASE_REF)));
        assertEq(res.assetCount(), 0, "pending");
        vm.prank(o1);
        vm.expectRevert("already confirmed");
        ms.confirm(cid);
        vm.prank(o2);
        ms.confirm(cid);
        assertEq(res.ownerOf(0), a);
    }

    /// یک کلید لو رفته به‌تنهایی هیچ کار اوراکلی نمیکند: نه بازتخصیص، نه انجماد ولت، نه ثبت ولت مهاجم؛
    /// مالک (timelock) اوراکل را به multisig جدید بدون کلید لو رفته میچرخاند
    function test_compromised_signer_contained() public {
        uint256 id = _mint(a, 5 ether);
        MultisigOracle ms = _multisigOracle();

        vm.startPrank(o3); // o3 لو رفته
        ms.submit(address(res), abi.encodeCall(RESNFT.reissueAsset, (id, x, CASE_REF)));
        ms.submit(address(res), abi.encodeCall(RESNFT.removeFromEligibleList, (a, CASE_REF)));
        ms.submit(address(res), abi.encodeCall(RESNFT.addToEligibleList, (makeAddr("attacker"), CASE_REF)));
        vm.expectRevert("only oracle");
        res.reissueAsset(id, x, CASE_REF);
        vm.stopPrank();
        assertEq(res.ownerOf(id), a, "single signer cannot steal");
        assertTrue(res.isEligible(a), "single signer cannot freeze");
        assertFalse(res.isEligible(makeAddr("attacker")));

        // چرخش: multisig جدید با o4 به‌جای o3
        address o4 = makeAddr("oracle4");
        address[] memory s = new address[](3);
        s[0] = o1; s[1] = o2; s[2] = o4;
        MultisigOracle ms2 = new MultisigOracle(s, 2);
        _appoint(address(ms2));
        assertEq(res.oracleAddress(), address(ms2));

        // پیشنهادهای معلق روی multisig قدیمی حتی با امضای دوم بی‌اثرند
        vm.prank(o1);
        vm.expectRevert("only oracle");
        ms.confirm(0);
        assertEq(res.ownerOf(id), a);
    }

    /// جایگزینی اوراکل: آدرس جدید درخواست میدهد و تا تأیید مالک، اوراکل قبلی برقرار است
    function test_oracle_rotation_needs_request_and_approval() public {
        vm.prank(owner);
        vm.expectRevert("no such request");
        res.approveOracle(IR, o2); // بدون درخواست خود آدرس، تأیید ممکن نیست
        vm.prank(o2);
        res.requestOracle(IR, address(0));
        assertEq(res.oracleOf(IR), o1, "not active before approval");
        vm.prank(o1);
        vm.expectRevert();
        res.approveOracle(IR, o2); // اوراکل فعلی اختیار تأیید ندارد
        vm.prank(owner);
        res.approveOracle(IR, o2);
        assertEq(res.oracleOf(IR), o2);
        vm.prank(owner);
        vm.expectRevert("no such request");
        res.approveOracle(IR, o2); // درخواست مصرف شد
        vm.prank(o1);
        vm.expectRevert("only oracle");
        res.addToEligibleList(x, CASE_REF);
    }

    function test_pause_blocks_market() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        vm.prank(owner); // در استقرار واقعی: شورا با ۲/۳
        res.pause();
        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        res.buy{value: 1 ether}(id);
        vm.prank(a);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        res.transferFrom(a, b, id);
        // بازتخصیص قانونی حین توقف مجاز است (مسیر بازیابی)
        vm.prank(o1);
        res.reissueAsset(id, b, CASE_REF);
        assertEq(res.ownerOf(id), b);
    }

    // ---------------- ولت: انجماد، بازیابی، امضا ----------------

    /// ولت حذف‌شده به دستور مرجع قانونی منجمد است؛ انتقال قانونی دارایی با reissue اوراکل
    function test_frozen_wallet_and_recovery() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        vm.prank(o1);
        res.removeFromEligibleList(a, CASE_REF);

        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert("sender not eligible");
        res.buy{value: 1 ether}(id);
        vm.prank(a);
        vm.expectRevert("sender not eligible");
        res.transferFrom(a, b, id);
        vm.prank(a);
        vm.expectRevert("sender not eligible");
        res.split(id, _arr(50, 50), _addrs(b, b));

        address aNew = makeAddr("aliceNewWallet");
        vm.startPrank(o1);
        res.addToEligibleList(aNew, CASE_REF);
        res.reissueAsset(id, aNew, CASE_REF);
        vm.stopPrank();
        assertEq(res.ownerOf(id), aNew);
    }

    /// رفع انجماد به دستور مرجع: ولت به لیست برمیگردد و مالک دوباره میتواند بفروشد
    function test_unfreeze_restores_rights() public {
        uint256 id = _mint(a, 1 ether);
        vm.prank(o1);
        res.removeFromEligibleList(a, CASE_REF);
        vm.prank(a);
        vm.expectRevert("sender not eligible");
        res.transferFrom(a, b, id);
        vm.prank(o1);
        res.addToEligibleList(a, CASE_REF);
        vm.prank(a);
        res.transferFrom(a, b, id);
        assertEq(res.ownerOf(id), b);
    }

    function test_register_wallet_signature_and_replay() public {
        (address w, uint256 pk) = makeAddrAndKey("newUser");
        bytes32 commit = keccak256(abi.encode("salt-123", "national-id-hash"));
        bytes memory sig = _sign(pk, res.walletBindingHash(w, commit));

        vm.prank(o1);
        res.registerWallet(w, commit, sig, CASE_REF);
        assertTrue(res.isEligible(w));
        assertEq(res.identityOf(w), commit);

        // replay همان امضا: nonce جلو رفته
        vm.prank(o1);
        vm.expectRevert("bad wallet signature");
        res.registerWallet(w, commit, sig, CASE_REF);
    }

    function test_register_wallet_rejects_forged_signature() public {
        (address w,) = makeAddrAndKey("victim");
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        bytes32 commit = keccak256("id");
        bytes memory sig = _sign(attackerPk, res.walletBindingHash(w, commit));
        vm.prank(o1);
        vm.expectRevert("bad wallet signature");
        res.registerWallet(w, commit, sig, CASE_REF);
    }

    /// امضا به قرارداد و زنجیره گره خورده: روی زنجیره دیگر معتبر نیست
    function test_register_wallet_cross_chain_replay() public {
        (address w, uint256 pk) = makeAddrAndKey("user2");
        bytes32 commit = keccak256("id2");
        bytes memory sig = _sign(pk, res.walletBindingHash(w, commit));
        vm.chainId(1);
        vm.prank(o1);
        vm.expectRevert("bad wallet signature");
        res.registerWallet(w, commit, sig, CASE_REF);
    }

    // ---------------- پرداخت و ترتیب تراکنش ----------------

    /// فروشنده مخرب که اتر را رد میکند: کل خرید revert، هیچ وضعیت نیمه‌کاره‌ای نمیماند
    function test_malicious_seller_rejecting_payment() public {
        RejectingSeller rs = new RejectingSeller(res);
        vm.prank(o1);
        res.addToEligibleList(address(rs), CASE_REF);
        uint256 id = _mint(address(rs), 1 ether);
        rs.list(id);
        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert("seller transfer failed");
        res.buy{value: 1 ether}(id);
        assertEq(res.ownerOf(id), address(rs));
        (, bool forSale,,,,,,,) = res.getAsset(id);
        assertTrue(forSale);
        assertEq(b.balance, 1 ether);
        assertEq(address(res).balance, 0);
    }

    /// front-running: فروشنده قیمت را پیش از تأیید تراکنش خریدار بالا میبرد → خرید revert، پولی گم نمیشود
    function test_front_running_price_change() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        vm.prank(a);
        res.changePrice(id, 3 ether); // در همان بلاک، جلوتر از خریدار
        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert("wrong value");
        res.buy{value: 1 ether}(id);
        assertEq(b.balance, 1 ether);
    }

    /// دو خریدار همزمان: اولی برنده، دومی revert (دوبار فروش ممکن نیست)
    function test_concurrent_buyers() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        vm.deal(b, 1 ether);
        vm.deal(x, 1 ether);
        vm.prank(b);
        res.buy{value: 1 ether}(id);
        vm.prank(x);
        vm.expectRevert("not for sale");
        res.buy{value: 1 ether}(id);
        assertEq(a.balance, 1 ether);
        assertEq(x.balance, 1 ether);
    }

    function test_cannot_list_without_price() public {
        uint256 id = _mint(a, 1 ether);
        _list(a, id);
        vm.deal(b, 1 ether);
        vm.prank(b);
        res.buy{value: 1 ether}(id); // قیمت بعد از فروش پاک میشود
        vm.prank(b);
        vm.expectRevert("set price first");
        res.setForSale(id, true);
    }

    // ---------------- تقسیم و ادغام ----------------

    function test_invalid_fractionalization() public {
        uint256 id = _mint(a, 1 ether);
        vm.startPrank(a);
        vm.expectRevert("percents must sum to parent");
        res.split(id, _arr(50, 49), _addrs(a, b));
        vm.expectRevert("bad percent");
        res.split(id, _arr(100, 0), _addrs(a, b));
        address[] memory many = new address[](21);
        uint256[] memory p = new uint256[](21);
        for (uint256 i; i < 21; ++i) { many[i] = a; p[i] = i == 0 ? 80 : 1; }
        vm.expectRevert("too many shares");
        res.split(id, p, many);
        vm.expectRevert("receiver not eligible");
        res.split(id, _arr(50, 50), _addrs(a, makeAddr("nobody")));
        vm.stopPrank();
    }

    function test_invalidated_parent_and_child_rules() public {
        uint256 id = _mint(a, 1 ether);
        uint256[] memory kids = _split(a, id, _arr(70, 30), _addrs(a, a));
        // والد ساقط‌شده قابل انتقال/فروش/تقسیم مجدد نیست
        vm.startPrank(a);
        vm.expectRevert();
        res.transferFrom(a, b, id);
        vm.expectRevert();
        res.setForSale(id, true);
        vm.expectRevert();
        res.split(id, _arr(50, 50), _addrs(a, b));
        // سهم قابل تقسیم مجدد نیست
        vm.expectRevert("already split / child");
        res.split(kids[0], _arr(35, 35), _addrs(a, b));
        vm.stopPrank();
    }

    /// چرخه کامل split → merge → split → merge (ایندکس فرزندان درست بازنشانی میشود)
    function test_split_merge_cycle() public {
        uint256 id = _mint(a, 1 ether);
        _split(a, id, _arr(70, 30), _addrs(a, a));
        vm.prank(a);
        res.merge(id);
        assertEq(res.childrenOf(id).length, 0);
        uint256[] memory kids2 = _split(a, id, _arr(25, 25, 50), _addrs3(a, a, b));
        assertEq(res.childrenOf(id).length, 3);
        vm.prank(a);
        vm.expectRevert("caller does not own all children");
        res.merge(id);
        vm.prank(b);
        res.transferFrom(b, a, kids2[2]);
        vm.prank(a);
        res.merge(id);
        assertEq(res.ownerOf(id), a);
    }

    // ---------------- مقداردهی و ارتقا ----------------

    function test_initializers_locked() public {
        vm.expectRevert();
        res.initialize(IR);
        vm.prank(owner);
        vm.expectRevert();
        res.initializeV2(IR);
    }

    /// ارتقای پروکسی v3 (همان کد دیپلوی‌شده روی Sepolia) به v4: داده حفظ، باگ تخفیف کهنه بی‌اثر
    function test_upgrade_from_v3() public {
        vm.startPrank(owner);
        RESNFTv3 implV3 = new RESNFTv3();
        RESNFTv3 old = RESNFTv3(payable(address(new ERC1967Proxy(address(implV3), abi.encodeCall(RESNFTv3.initialize, ())))));
        old.addToEligibleList(a);
        old.addToEligibleList(x);
        old.addAsset(10 ether, a);
        vm.stopPrank();
        vm.startPrank(a);
        old.setForSale(0, true);
        old.setCustomPrice(0, x, 1 wei); // تخفیف v3 در اسلات قدیمی
        vm.stopPrank();

        RESNFT implV4 = new RESNFT();
        vm.prank(owner);
        old.upgradeToAndCall(address(implV4), abi.encodeCall(RESNFT.initializeV2, (IR)));
        RESNFT up = RESNFT(payable(address(old)));

        assertEq(up.ownerOf(0), a);
        assertTrue(up.isEligible(x));
        assertEq(up.oracleAddress(), owner);
        assertEq(up.oracleOf(IR), owner);
        assertEq(up.jurisdictionOf(0), IR, "v3 assets fall in the default jurisdiction");
        (uint256 price, bool forSale,,,,,,,) = up.getAsset(0);
        assertEq(price, 10 ether);
        assertTrue(forSale);
        assertEq(up.customPrice(0, x), 0, "legacy discount slot ignored");
        vm.prank(owner);
        vm.expectRevert();
        up.initializeV2(IR);
    }

    // ---------------- fuzz ----------------

    function testFuzz_split_two_parts(uint8 p) public {
        p = uint8(bound(p, 1, 99));
        uint256 id = _mint(a, 1 ether);
        uint256[] memory kids = _split(a, id, _arr(p, 100 - uint256(p)), _addrs(a, b));
        (,,, uint256 p0,,,,,) = res.getAsset(kids[0]);
        (,,, uint256 p1,,,,,) = res.getAsset(kids[1]);
        assertEq(p0 + p1, 100);
    }

    function testFuzz_buy_requires_exact_value(uint96 price, uint96 paid) public {
        vm.assume(price > 0 && paid != price);
        uint256 id = _mint(a, price);
        _list(a, id);
        vm.deal(b, paid);
        vm.prank(b);
        vm.expectRevert("wrong value");
        res.buy{value: paid}(id);
    }

    // ---------------- helpers ----------------

    function _split(address who, uint256 id, uint256[] memory p, address[] memory to)
        internal returns (uint256[] memory)
    {
        vm.prank(who);
        return res.split(id, p, to);
    }

    function _sign(uint256 pk, bytes32 h) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(h));
        return abi.encodePacked(r, s, v);
    }

    function _arr(uint256 p0, uint256 p1) internal pure returns (uint256[] memory r) {
        r = new uint256[](2); r[0] = p0; r[1] = p1;
    }

    function _arr(uint256 p0, uint256 p1, uint256 p2) internal pure returns (uint256[] memory r) {
        r = new uint256[](3); r[0] = p0; r[1] = p1; r[2] = p2;
    }

    function _addrs(address x0, address x1) internal pure returns (address[] memory r) {
        r = new address[](2); r[0] = x0; r[1] = x1;
    }

    function _addrs3(address x0, address x1, address x2) internal pure returns (address[] memory r) {
        r = new address[](3); r[0] = x0; r[1] = x1; r[2] = x2;
    }
}

/// فروشنده‌ای که پرداخت را رد میکند (توکن/قرارداد مخرب در مسیر پرداخت)
contract RejectingSeller {
    RESNFT immutable res;
    constructor(RESNFT r) { res = r; }
    function list(uint256 id) external { res.setForSale(id, true); }
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    receive() external payable { revert("no thanks"); }
}
