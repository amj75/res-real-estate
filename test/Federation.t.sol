// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// اوراکل فدرال: هر کشور یک اوراکل (multisig مرجع ثبت همان کشور)، مالک قرارداد = OracleCouncil (DAO کشورها).
/// خرید بین‌المللی، تفکیک حوزه قضایی، انجماد سراسری/محلی، تعلیق فوری اوراکل لو رفته با ۲/۳ اعضا،
/// درخواست آدرس جدید توسط خود کشور و تأیید ۲/۳ DAO، کلید محافظ، عضویت کشور جدید، ارتقا از طریق DAO.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";
import "../contracts/OracleCouncil.sol";

// مرجع پرونده ثبتی آزمایشی (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract FederationTest is Test {
    uint16 constant IR = 364;
    uint16 constant DE = 276;
    uint16 constant TR = 792;
    uint16 constant AE = 784;
    uint16 constant FR = 250;

    RESNFT res;
    OracleCouncil council;
    address deployer = makeAddr("deployer");
    address oIR = makeAddr("oracleIR");
    address oDE = makeAddr("oracleDE");
    address oTR = makeAddr("oracleTR");
    address oAE = makeAddr("oracleAE");
    address gIR = makeAddr("guardianIR");
    address gDE = makeAddr("guardianDE");

    address ali = makeAddr("ali");       // احراز: ایران
    address hans = makeAddr("hans");     // احراز: آلمان
    address mehmet = makeAddr("mehmet"); // احراز: ترکیه

    uint256 house; // ملک ایران، مالک ali
    uint256 flat;  // ملک آلمان، مالک hans

    function setUp() public {
        vm.prank(deployer);
        RESNFT impl = new RESNFT();
        vm.prank(deployer);
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (IR))))));
        _request(IR, oIR, gIR);
        _request(DE, oDE, gDE);
        _request(TR, oTR, address(0));
        _request(AE, oAE, address(0));
        vm.startPrank(deployer); // راه‌اندازی: اعضای مؤسس پیش از انتقال مالکیت به DAO
        res.approveOracle(IR, oIR);
        res.approveOracle(DE, oDE);
        res.approveOracle(TR, oTR);
        res.approveOracle(AE, oAE);
        council = new OracleCouncil(res);
        res.transferOwnership(address(council));
        vm.stopPrank();

        vm.prank(oIR); res.addToEligibleList(ali, CASE_REF);
        vm.prank(oDE); res.addToEligibleList(hans, CASE_REF);
        vm.prank(oTR); res.addToEligibleList(mehmet, CASE_REF);
        vm.prank(oIR); house = res.addAsset(10 ether, ali, CASE_REF);
        vm.prank(oDE); flat = res.addAsset(5 ether, hans, CASE_REF);
    }

    // ---------------- بازار بدون مرز ----------------

    function test_setup_state() public view {
        assertEq(res.countries().length, 4);
        assertEq(res.oracleOf(DE), oDE);
        assertEq(res.oracleAddress(), oIR, "default country oracle mirrors oracleAddress");
        assertEq(res.owner(), address(council));
        assertEq(res.jurisdictionOf(house), IR);
        assertEq(res.jurisdictionOf(flat), DE);
        assertEq(res.registrarOf(hans), DE);
    }

    /// خریدار احرازشده در آلمان ملک ایران را میخرد
    function test_cross_border_purchase() public {
        _list(ali, house);
        vm.deal(hans, 10 ether);
        vm.prank(hans);
        res.buy{value: 10 ether}(house);
        assertEq(res.ownerOf(house), hans);
        assertEq(ali.balance, 10 ether);
        assertEq(res.jurisdictionOf(house), IR, "jurisdiction follows the property, not the owner");
    }

    /// اوراکل هر کشور فقط ملک‌های حوزه خودش را مدیریت میکند
    function test_jurisdiction_isolation() public {
        vm.startPrank(oDE);
        vm.expectRevert("wrong jurisdiction");
        res.reissueAsset(house, hans, CASE_REF);
        vm.expectRevert("wrong jurisdiction");
        res.changeRenter(house, hans, CASE_REF);
        vm.expectRevert("wrong jurisdiction");
        res.setRent(house, hans, 1, 2, CASE_REF);
        vm.stopPrank();
        // سهم‌ها در حوزه والد میمانند
        uint256[] memory kids = _split(hans, flat);
        assertEq(res.jurisdictionOf(kids[0]), DE);
        vm.prank(oIR);
        vm.expectRevert("wrong jurisdiction");
        res.reissueAsset(kids[0], ali, CASE_REF);
    }

    /// ولتی که یک کشور احراز کرده فقط در اختیار همان کشور است
    function test_registrar_controls_wallet() public {
        vm.startPrank(oIR);
        vm.expectRevert("not registrar");
        res.removeFromEligibleList(hans, CASE_REF);
        vm.expectRevert("registered by another country");
        res.addToEligibleList(hans, CASE_REF);
        vm.stopPrank();
    }

    // ---------------- انجماد به دستور مرجع قانونی ----------------

    /// انجماد سراسری توسط کشور احرازکننده: ولت در هیچ کشوری معامله نمیکند
    function test_global_freeze_by_registrar() public {
        _list(ali, house);
        vm.prank(oDE);
        res.removeFromEligibleList(hans, CASE_REF);

        vm.deal(hans, 10 ether);
        vm.prank(hans);
        vm.expectRevert("buyer not eligible");
        res.buy{value: 10 ether}(house); // ملک ایران
        vm.prank(hans);
        vm.expectRevert("sender not eligible");
        res.transferFrom(hans, mehmet, flat); // ملک آلمان
        vm.prank(ali);
        vm.expectRevert("receiver not eligible");
        res.transferFrom(ali, hans, house);

        vm.prank(oDE);
        res.addToEligibleList(hans, CASE_REF); // رفع انجماد فقط توسط همان کشور
        vm.prank(hans);
        res.transferFrom(hans, mehmet, flat);
        assertEq(res.ownerOf(flat), mehmet);
    }

    /// انجماد محلی: ایران فقط ملک‌های حوزه خودش را برای این ولت میبندد
    function test_local_freeze_only_in_jurisdiction() public {
        _list(ali, house);
        vm.deal(hans, 10 ether);
        vm.prank(hans);
        res.buy{value: 10 ether}(house);

        vm.prank(oIR);
        res.freezeLocal(hans, true, CASE_REF);
        vm.prank(hans);
        vm.expectRevert("sender not eligible");
        res.transferFrom(hans, mehmet, house); // ملک ایران: منجمد
        vm.prank(hans);
        res.transferFrom(hans, mehmet, flat);  // ملک آلمان: آزاد
        assertEq(res.ownerOf(flat), mehmet);
        assertTrue(res.isEligible(hans));

        // اجرای حکم دادگاه ایران: انتقال قانونی ملک ایران
        vm.prank(oIR);
        res.reissueAsset(house, ali, CASE_REF);
        assertEq(res.ownerOf(house), ali);
    }

    // ---------------- DAO: تعلیق، انتصاب، محافظ، عضویت ----------------

    /// اوراکل آلمان لو رفته: ۲ از ۳ عضو دیگر (۲/۳، بدون رأی خود آلمان) آن را فوراً تعلیق میکنند
    function test_council_suspends_compromised_oracle() public {
        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.suspend, (DE)));
        assertFalse(res.suspended(DE), "1 of 3 is not enough");
        vm.prank(oDE);
        council.vote(pid); // رأی خود متهم شمرده نمیشود
        assertFalse(res.suspended(DE));
        vm.prank(oTR);
        council.vote(pid);
        assertTrue(res.suspended(DE), "2 of 3 suspends immediately");

        vm.startPrank(oDE);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, hans, CASE_REF);
        vm.expectRevert("only oracle");
        res.addToEligibleList(makeAddr("fake"), CASE_REF);
        vm.expectRevert("not member");
        council.propose(abi.encodeCall(RESNFT.suspend, (IR)));
        vm.stopPrank();

        // ملک‌های آلمان و ولت‌هایی که آلمان احراز کرده تا انتصاب جدید معامله نمیشوند
        vm.prank(hans);
        vm.expectRevert("jurisdiction suspended");
        res.transferFrom(hans, mehmet, flat);
        assertFalse(res.isEligible(hans));
        // بقیه کشورها بی‌تأثیر
        vm.prank(ali);
        res.transferFrom(ali, mehmet, house);
        assertEq(res.ownerOf(house), mehmet);
    }

    /// آلمان آدرس جدید را درخواست میدهد؛ DAO پس از بررسی خارج از زنجیره با ۲/۳ تأیید میکند
    function test_appoint_new_oracle_after_compromise() public {
        _suspendDE();
        address oDE2 = makeAddr("oracleDE2");
        _request(DE, oDE2, gDE);
        // مهاجم (اوراکل قبلی) هم میتواند درخواست بدهد؛ DAO فقط آدرس بررسی‌شده را تأیید میکند
        _request(DE, oDE, address(0));
        assertTrue(res.suspended(DE), "a request alone changes nothing");

        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.approveOracle, (DE, oDE2)));
        assertTrue(res.suspended(DE), "1 of 3 is not enough");
        vm.prank(oTR);
        council.vote(pid);

        assertFalse(res.suspended(DE), "2 of 3 approves immediately");
        assertEq(res.guardianOf(DE), gDE);
        assertEq(res.oracleOf(DE), oDE2);
        assertEq(res.countryOf(oDE), 0);
        assertTrue(res.isEligible(hans));
        vm.prank(hans);
        res.transferFrom(hans, mehmet, flat);
        vm.prank(oDE);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, hans, CASE_REF);
    }

    /// کلید محافظ: خود مرجع ثبت هک را کشف میکند و اوراکلش را فوراً تعلیق میکند؛ کار دیگری نمیتواند
    function test_guardian_self_suspend() public {
        vm.prank(gIR);
        vm.expectRevert("not guardian");
        res.suspendSelf(DE);
        vm.prank(gIR);
        res.suspendSelf(IR);
        assertTrue(res.suspended(IR));
        vm.prank(oIR);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, ali, CASE_REF);
        vm.prank(gIR);
        vm.expectRevert("only oracle");
        res.addAsset(1 ether, ali, CASE_REF);

        // هشدار نادرست / پس از بازیابی: ایران همان آدرس را دوباره درخواست میدهد و DAO تأیید میکند
        _request(IR, oIR, gIR);
        uint256 pid = _propose(oDE, abi.encodeCall(RESNFT.approveOracle, (IR, oIR)));
        vm.prank(oTR);
        council.vote(pid);
        assertFalse(res.suspended(IR));
    }

    /// عضویت کشور جدید با ۲/۳ اعضا (۳ از ۴)
    function test_join_new_country() public {
        address oFR = makeAddr("oracleFR");
        _request(FR, oFR, address(0));
        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.approveOracle, (FR, oFR)));
        vm.prank(oDE);
        council.vote(pid);
        assertEq(res.oracleOf(FR), address(0), "2 of 4 is not enough");
        vm.prank(oTR);
        council.vote(pid);
        assertEq(res.oracleOf(FR), oFR);
        assertEq(res.countries().length, 5);

        address pierre = makeAddr("pierre");
        vm.prank(oFR); res.addToEligibleList(pierre, CASE_REF);
        vm.prank(oFR); uint256 villa = res.addAsset(3 ether, pierre, CASE_REF);
        assertEq(res.jurisdictionOf(villa), FR);
    }

    /// اوراکل یک کشور نمیتواند برای کشور دیگری درخواست دهد؛ DAO هم بدون درخواست خود آدرس نمیتواند منصوب کند
    function test_oracle_address_unique_and_request_required() public {
        vm.prank(oDE);
        vm.expectRevert("oracle of another country");
        res.requestOracle(FR, address(0));

        address stranger = makeAddr("stranger");
        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.approveOracle, (FR, stranger)));
        vm.prank(oTR);
        council.vote(pid);
        vm.prank(oAE); // رأی سوم = ۲/۳ → اجرا → رد: آدرس خودش درخواست نداده
        vm.expectRevert("no such request");
        council.vote(pid);
    }

    /// ارتقا و unpause هم فقط با ۲/۳ DAO
    function test_upgrade_and_unpause_via_council() public {
        vm.prank(oTR);
        res.pause();
        vm.prank(oTR);
        vm.expectRevert();
        res.unpause();

        RESNFT impl2 = new RESNFT();
        uint256 pid = _propose(oIR, abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(impl2), ""));
        vm.prank(oDE);
        council.vote(pid);
        vm.prank(oAE);
        council.vote(pid);
        assertEq(res.ownerOf(house), ali, "state kept after upgrade");

        uint256 pid2 = _propose(oIR, abi.encodeCall(RESNFT.unpause, ()));
        vm.prank(oDE); council.vote(pid2);
        vm.prank(oAE); council.vote(pid2);
        assertFalse(res.paused());
    }

    function test_proposal_rules() public {
        vm.prank(ali);
        vm.expectRevert("not member");
        council.propose(abi.encodeCall(RESNFT.suspend, (DE)));

        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.suspend, (DE)));
        vm.prank(oIR);
        vm.expectRevert("already voted");
        council.vote(pid);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(oTR);
        vm.expectRevert("expired");
        council.vote(pid);
    }

    // ---------------- مرجع پرونده ثبتی ----------------

    /// هیچ اقدام اوراکلی بدون مرجع پرونده ثبتی پذیرفته نمیشود
    function test_case_reference_required() public {
        vm.startPrank(oIR);
        vm.expectRevert("case reference required");
        res.addAsset(1 ether, ali, bytes32(0));
        vm.expectRevert("case reference required");
        res.reissueAsset(house, ali, bytes32(0));
        vm.expectRevert("case reference required");
        res.addToEligibleList(makeAddr("new"), bytes32(0));
        vm.expectRevert("case reference required");
        res.removeFromEligibleList(ali, bytes32(0));
        vm.expectRevert("case reference required");
        res.freezeLocal(hans, true, bytes32(0));
        vm.expectRevert("case reference required");
        res.changeRenter(house, ali, bytes32(0));
        vm.stopPrank();
    }

    /// هر اقدام: رویداد OracleAction(کشور، مرجع پرونده، تابع) روی زنجیره
    function test_case_reference_emitted() public {
        bytes32 deed = keccak256(abi.encode(IR, "deed-1403-7781", "salt"));
        vm.expectEmit(true, true, true, false, address(res));
        emit RESNFT.OracleAction(IR, deed, RESNFT.addAsset.selector);
        vm.prank(oIR);
        res.addAsset(2 ether, ali, deed);
    }

    /// کشف هک با تطبیق: ناظر رویدادهای OracleAction آلمان را با پرونده‌های مرجع ثبت آلمان مقایسه میکند؛
    /// اقدام مهاجم (کلید لو رفته) پرونده متناظر ندارد → هشدار → کلید محافظ اوراکل را فوراً تعلیق میکند
    function test_unregistered_case_is_detectable() public {
        bytes32 legit = keccak256(abi.encode(DE, "AZ-2026-0042", "salt"));
        bytes32[] memory registryFiles = new bytes32[](1); // پرونده‌های واقعی دفتر ثبت آلمان (آف‌چین)
        registryFiles[0] = legit;

        vm.recordLogs();
        vm.prank(oDE);
        res.addAsset(1 ether, hans, legit);                        // اقدام قانونی
        vm.prank(oDE);
        res.reissueAsset(flat, hans, keccak256("fabricated"));     // مهاجم با کلید لو رفته
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 alarms;
        bytes32 sig = RESNFT.OracleAction.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || uint256(logs[i].topics[1]) != DE) continue;
            bool known;
            for (uint256 k; k < registryFiles.length; ++k) known = known || logs[i].topics[2] == registryFiles[k];
            if (!known) alarms++;
        }
        assertEq(alarms, 1, "exactly the attacker's action is flagged");

        vm.prank(gDE);
        res.suspendSelf(DE);
        assertTrue(res.suspended(DE));
    }

    // ---------------- helpers ----------------

    function _request(uint16 c, address o, address guardian) internal {
        vm.prank(o);
        res.requestOracle(c, guardian);
    }

    function _propose(address member, bytes memory data) internal returns (uint256 pid) {
        vm.prank(member);
        pid = council.propose(data);
    }

    function _suspendDE() internal {
        uint256 pid = _propose(oIR, abi.encodeCall(RESNFT.suspend, (DE)));
        vm.prank(oTR);
        council.vote(pid);
        assertTrue(res.suspended(DE));
    }

    function _list(address who, uint256 id) internal {
        vm.prank(who);
        res.setForSale(id, true);
    }

    function _split(address who, uint256 id) internal returns (uint256[] memory) {
        uint256[] memory p = new uint256[](2);
        address[] memory t = new address[](2);
        p[0] = 50; p[1] = 50; t[0] = who; t[1] = who;
        vm.prank(who);
        return res.split(id, p, t);
    }
}
