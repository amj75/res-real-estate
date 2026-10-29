// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// هزینه هر تابع (داور ۲، بند ۱۱): گس کامل تراکنش + سربار ذخیره‌سازی (اسلات‌های تازه/آزادشده)
/// خروجی در لاگ: COST,<function>,<txGas>,<newSlots>,<freedSlots>
/// اجرا: forge test --match-contract Cost -vv --isolate | grep -o "COST,.*"
/// --isolate ضروری است (مثل Scalability): هر فراخوانی تراکنش جدا با storage سرد.
/// ضبط state diff خودش اسلات‌ها را warm میکند و گس را کمتر نشان میدهد؛ پس دو اجرا:
///   NO_DIFF=true → ستون گس؛ بدون آن → ستون‌های اسلات (گس آن اجرا استفاده نمیشود)
/// newSlots = اسلات‌هایی که از صفر به ناصفر رفتند (هر کدام ۳۲ بایت حالت دائمی شبکه)؛
/// freedSlots = اسلات‌هایی که به صفر برگشتند (بازپرداخت گس). خروجی: results/cost.csv
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../contracts/OracleCouncil.sol";
import "../contracts/RESNFT.sol";

bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract CostTest is Test {
    RESNFT res;
    address oracle = makeAddr("oracle");
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");

    function setUp() public {
        vm.startPrank(oracle);
        RESNFT impl = new RESNFT();
        res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (uint16(364)))))));
        res.addToEligibleList(a, CASE_REF);
        res.addToEligibleList(b, CASE_REF);
        res.addToEligibleList(c, CASE_REF);
        res.addAsset(1 ether, c, CASE_REF); // حالت پایدار: شمارنده‌ها ناصفرند (مثل Scalability)
        vm.stopPrank();
    }

    function _begin() internal {
        if (!vm.envOr("NO_DIFF", false)) vm.startStateDiffRecording();
    }

    /// گس آخرین فراخوانی + شمارش تغییر خالص اسلات‌ها در همان فراخوانی
    function _end(string memory fn) internal {
        if (vm.envOr("NO_DIFF", false)) {
            console.log(string.concat("COST,", fn, ",", vm.toString(vm.lastCallGas().gasTotalUsed)));
            return;
        }
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 n;
        for (uint256 i; i < acc.length; ++i) n += acc[i].storageAccesses.length;
        bytes32[] memory key = new bytes32[](n);
        bytes32[] memory first = new bytes32[](n);
        bytes32[] memory last = new bytes32[](n);
        uint256 k;
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = acc[i].storageAccesses[j];
                if (!s.isWrite) continue;
                bytes32 id = keccak256(abi.encode(s.account, s.slot));
                uint256 x;
                while (x < k && key[x] != id) ++x;
                if (x == k) { key[k] = id; first[k] = s.previousValue; ++k; }
                last[x] = s.newValue;
            }
        }
        uint256 created;
        uint256 freed;
        for (uint256 x; x < k; ++x) {
            if (first[x] == 0 && last[x] != 0) ++created;
            if (first[x] != 0 && last[x] == 0) ++freed;
        }
        console.log(string.concat("COST,", fn, ",", vm.toString(vm.lastCallGas().gasTotalUsed), ",",
            vm.toString(created), ",", vm.toString(freed)));
    }

    function _shares(uint256 n, address to) internal pure returns (uint256[] memory p, address[] memory t) {
        p = new uint256[](n);
        t = new address[](n);
        uint256 left = 100;
        for (uint256 i; i < n; ++i) {
            p[i] = i == n - 1 ? left : 100 / n;
            left -= p[i];
            t[i] = to;
        }
    }

    function test_cost_per_function() public {
        // ---------- هویت و فهرست مجاز ----------
        (address w, uint256 pk) = makeAddrAndKey("wallet");
        bytes32 commit = keccak256("salt|national-id");
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(res.walletBindingHash(w, commit));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        _begin(); vm.prank(oracle); res.registerWallet(w, commit, abi.encodePacked(r, s, v), CASE_REF); _end("registerWallet");
        _begin(); vm.prank(oracle); res.addToEligibleList(makeAddr("new"), CASE_REF);              _end("addToEligibleList");
        _begin(); vm.prank(oracle); res.removeFromEligibleList(makeAddr("new"), CASE_REF);         _end("removeFromEligibleList");
        _begin(); vm.prank(oracle); res.freezeLocal(makeAddr("frozen"), true, CASE_REF);           _end("freezeLocal");

        // ---------- ملک و بازار ----------
        _begin(); vm.prank(oracle); uint256 id = res.addAsset(1 ether, a, CASE_REF);               _end("addAsset");
        _begin(); vm.prank(a); res.setForSale(id, true);                                           _end("setForSale");
        _begin(); vm.prank(a); res.changePrice(id, 2 ether);                                       _end("changePrice");
        _begin(); vm.prank(a); res.setCustomPrice(id, b, 1 ether);                                 _end("setCustomPrice");
        vm.deal(b, 1 ether);
        _begin(); vm.prank(b); res.buy{value: 1 ether}(id);                                        _end("buy");
        _begin(); vm.prank(b); res.approve(a, id);                                                 _end("approve");
        _begin(); vm.prank(a); res.transferFrom(b, a, id);                                         _end("transferFrom");
        _begin(); vm.prank(a); res.safeTransferFrom(a, b, id);                                     _end("safeTransferFrom");
        _begin(); vm.prank(b); res.transferDirect(id, a);                                          _end("transferDirect");

        // ---------- حق استفاده و حکم ----------
        _begin(); vm.prank(oracle); res.setRent(id, b, 1_700_000_000, 1_800_000_000, CASE_REF);    _end("setRent");
        _begin(); vm.prank(oracle); res.changeRenter(id, c, CASE_REF);                             _end("changeRenter");
        _begin(); vm.prank(oracle); res.reissueAsset(id, b, CASE_REF);                             _end("reissueAsset");

        // ---------- تقسیم و ادغام ----------
        (uint256[] memory p2, address[] memory t2) = _shares(2, b);
        _begin(); vm.prank(b); res.split(id, p2, t2);                                              _end("split(2)");
        _begin(); vm.prank(b); res.merge(id);                                                      _end("merge(2)");
        (uint256[] memory p20, address[] memory t20) = _shares(20, b);
        _begin(); vm.prank(b); res.split(id, p20, t20);                                            _end("split(20)");
        _begin(); vm.prank(b); res.merge(id);                                                      _end("merge(20)");

        // ---------- حاکمیت (قبل از انتقال مالکیت: مالک = استقرارکننده) ----------
        address oDE = makeAddr("oDE");
        address oTR = makeAddr("oTR");
        address gDE = makeAddr("gDE");
        _begin(); vm.prank(oDE); res.requestOracle(276, gDE);                                      _end("requestOracle");
        _begin(); vm.prank(oracle); res.approveOracle(276, oDE);                                   _end("approveOracle(owner)");
        vm.prank(oTR); res.requestOracle(792, address(0));
        vm.prank(oracle); res.approveOracle(792, oTR);
        _begin(); vm.prank(oracle); res.pause();                                                   _end("pause");
        _begin(); vm.prank(oracle); res.unpause();                                                 _end("unpause(owner)");

        // ---------- شورا: سه کشور؛ تعلیق آلمان = رأی ۲ از ۲ واجد شرایط (آلمان رأی ندارد) ----------
        OracleCouncil council = new OracleCouncil(res);
        vm.prank(oracle); res.transferOwnership(address(council));
        bytes memory data = abi.encodeCall(RESNFT.suspend, (uint16(276)));
        _begin(); vm.prank(oracle); uint256 pid = council.propose(data);                           _end("council.propose");
        _begin(); vm.prank(oTR); council.vote(pid);                                                _end("council.vote(executes suspend)");
        assertTrue(res.suspended(276));
        _begin(); vm.prank(gDE); res.suspendSelf(276);                                             _end("suspendSelf");
    }
}
