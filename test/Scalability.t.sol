// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// بنچمارک مقیاس‌پذیری (داور ۲، بند ۱۲؛ داور ۱، بند ۶): گس اجرای هر تابع وقتی N ملک و N ولت
/// از قبل ثبت شده‌اند، برای نسخه فعلی (v4) و نسخه دیپلوی‌شده قبلی (v3).
/// خروجی CSV در لاگ: BENCH,<impl>,<N>,<function>,<executionGas>
/// اجرا: forge test --match-contract Scalability -vv --isolate | grep BENCH
/// --isolate ضروری است: هر فراخوانی تراکنش جدا با storage سرد میشود و عدد = گس کامل تراکنش
/// (شامل 21000 و calldata) — مطابق رسیدهای Sepolia. بدون آن، خواندن‌ها warm و ارقام کمتر از واقعیت‌اند.
/// خروجی در results/scalability.csv ذخیره میشود (فرمان در README).
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";
import "./legacy/RESNFTv3.sol";

// مرجع پرونده ثبتی آزمایشی (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
bytes32 constant CASE_REF = keccak256("registry-case-0001");

contract ScalabilityTest is Test {
    address oracle = makeAddr("oracle");
    address a = makeAddr("a");
    address b = makeAddr("b");

    function _sizes() internal pure returns (uint256[4] memory) {
        return [uint256(10), 100, 1000, 3000];
    }

    function _log(string memory impl, uint256 n, string memory fn) internal view {
        console.log(string.concat("BENCH,", impl, ",", vm.toString(n), ",", fn, ",",
            vm.toString(vm.lastCallGas().gasTotalUsed)));
    }

    function _shares(uint256 k, address to) internal pure returns (uint256[] memory p, address[] memory t) {
        p = new uint256[](k);
        t = new address[](k);
        uint256 left = 100;
        for (uint256 i; i < k; ++i) {
            p[i] = i == k - 1 ? left : 100 / k;
            left -= p[i];
            t[i] = to;
        }
    }

    function test_scalability_v4() public {
        uint256[4] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) _benchV4(sizes[s]);
    }

    function test_scalability_v3() public {
        uint256[4] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) _benchV3(sizes[s]);
    }

    function _benchV4(uint256 n) internal {
        vm.pauseGasMetering();
        vm.startPrank(oracle);
        RESNFT impl = new RESNFT();
        RESNFT res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (uint16(364)))))));
        res.addToEligibleList(a, CASE_REF);
        res.addToEligibleList(b, CASE_REF);
        for (uint256 i; i < n; ++i) {
            address w = address(uint160(0x10000 + i));
            res.addToEligibleList(w, CASE_REF);
            res.addAsset(1 ether, w, CASE_REF);
        }
        vm.stopPrank();
        vm.resumeGasMetering();

        vm.prank(oracle); res.addToEligibleList(address(uint160(0x900000 + n)), CASE_REF);  _log("v4", n, "addToEligibleList");
        vm.prank(oracle); uint256 id = res.addAsset(1 ether, a, CASE_REF);                  _log("v4", n, "addAsset");
        vm.prank(a); res.setForSale(id, true);                                     _log("v4", n, "setForSale");
        vm.prank(a); res.changePrice(id, 2 ether);                                 _log("v4", n, "changePrice");
        vm.prank(a); res.setCustomPrice(id, b, 1 ether);                           _log("v4", n, "setCustomPrice");
        vm.deal(b, 1 ether);
        vm.prank(b); res.buy{value: 1 ether}(id);                                  _log("v4", n, "buy");
        vm.prank(b); res.transferFrom(b, a, id);                                   _log("v4", n, "transferFrom");
        vm.prank(oracle); res.setRent(id, b, 1_700_000_000, 1_800_000_000, CASE_REF);        _log("v4", n, "setRent");
        vm.prank(oracle); res.changeRenter(id, a, CASE_REF);                                 _log("v4", n, "changeRenter");
        vm.prank(oracle); res.reissueAsset(id, a, CASE_REF);                                 _log("v4", n, "reissueAsset");

        (uint256[] memory p2, address[] memory t2) = _shares(2, a);
        vm.prank(a); res.split(id, p2, t2);                                        _log("v4", n, "split(2)");
        vm.prank(a); res.merge(id);                                                _log("v4", n, "merge(2)");
        (uint256[] memory p20, address[] memory t20) = _shares(20, a);
        vm.prank(a); res.split(id, p20, t20);                                      _log("v4", n, "split(20)");
        vm.prank(a); res.merge(id);                                                _log("v4", n, "merge(20)");
        _benchFederation(res, n);
    }

    /// کشور دوم (آلمان): ضرب در حوزه غیرپیش‌فرض و خرید بین‌المللی (خریدار احرازشده در ایران)
    function _benchFederation(RESNFT res, uint256 n) internal {
        address oDE = makeAddr("oDE");
        address hans = makeAddr("hans");
        vm.pauseGasMetering();
        vm.prank(oDE); res.requestOracle(276, address(0));
        vm.prank(oracle); res.approveOracle(276, oDE);
        vm.prank(oDE); res.addToEligibleList(hans, CASE_REF);
        vm.resumeGasMetering();
        vm.prank(oDE); uint256 id = res.addAsset(1 ether, hans, CASE_REF);                  _log("v4", n, "addAsset[foreign]");
        vm.prank(hans); res.setForSale(id, true);
        vm.deal(a, 1 ether);
        vm.prank(a); res.buy{value: 1 ether}(id);                                  _log("v4", n, "buy[cross-border]");
        vm.prank(oDE); res.freezeLocal(a, true, CASE_REF);                                   _log("v4", n, "freezeLocal");
    }

    function _benchV3(uint256 n) internal {
        vm.pauseGasMetering();
        vm.startPrank(oracle);
        RESNFTv3 impl = new RESNFTv3();
        RESNFTv3 res = RESNFTv3(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFTv3.initialize, ())))));
        res.addToEligibleList(a);
        res.addToEligibleList(b);
        for (uint256 i; i < n; ++i) {
            address w = address(uint160(0x10000 + i));
            res.addToEligibleList(w);
            res.addAsset(1 ether, w);
        }
        vm.stopPrank();
        vm.resumeGasMetering();

        vm.prank(oracle); uint256 id = res.addAsset(1 ether, a);                   _log("v3", n, "addAsset");
        vm.prank(a); res.setForSale(id, true);                                     _log("v3", n, "setForSale");
        vm.deal(b, 1 ether);
        vm.prank(b); res.buy{value: 1 ether}(id);                                  _log("v3", n, "buy");
        vm.prank(b); res.transferFrom(b, a, id);                                   _log("v3", n, "transferFrom");
        (uint256[] memory p2, address[] memory t2) = _shares(2, a);
        vm.prank(a); res.split(id, p2, t2);                                        _log("v3", n, "split(2)");
        vm.prank(a); res.merge(id);                                                _log("v3", n, "merge(2)");
        (uint256[] memory p20, address[] memory t20) = _shares(20, a);
        vm.prank(a); res.split(id, p20, t20);                                      _log("v3", n, "split(20)");
        vm.prank(a); res.merge(id);                                                _log("v3", n, "merge(20)");
    }
}
