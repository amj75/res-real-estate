// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// مقیاس‌پذیری شورا (داوری داخلی M10): گس پیشنهاد و رأی وقتی شورا c کشور عضو دارد.
/// هر رأی همه‌ی کشورها و رأی‌دهندگان را دوباره میشمارد، پس هزینه‌ی هر رأی O(c) و کل یک پیشنهاد O(c²) است.
/// سناریو: پیشنهاد تعلیق آخرین کشور؛ کشور موضوع رأی نمیدهد و در مخرج نیست، پس ceil(2(c-1)/3) رأی لازم است.
/// خروجی در لاگ: COUNCIL,<c>,<metric>,<gas> — metric: propose | vote_first | vote_exec | votes | total
/// اجرا: forge test --match-contract CouncilScale -vv --isolate | grep -o "COUNCIL,.*"
/// --isolate ضروری است (مثل Scalability): هر فراخوانی تراکنش جدا با storage سرد. خروجی: results/council_scale.csv
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";
import "../contracts/OracleCouncil.sol";

contract CouncilScaleTest is Test {
    address deployer = makeAddr("deployer");

    function _sizes() internal pure returns (uint256[5] memory) {
        return [uint256(3), 10, 30, 60, 100];
    }

    function _log(uint256 c, string memory metric, uint256 gas) internal pure {
        console.log(string.concat("COUNCIL,", vm.toString(c), ",", metric, ",", vm.toString(gas)));
    }

    function test_council_scaling() public {
        uint256[5] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) _bench(sizes[s]);
    }

    function _bench(uint256 c) internal {
        vm.pauseGasMetering();
        vm.prank(deployer);
        RESNFT impl = new RESNFT();
        vm.prank(deployer);
        RESNFT res = RESNFT(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(RESNFT.initialize, (uint16(100)))))));
        address[] memory o = new address[](c);
        for (uint256 i; i < c; ++i) {
            o[i] = makeAddr(string.concat("council", vm.toString(c), "-", vm.toString(i)));
            vm.prank(o[i]);
            res.requestOracle(uint16(101 + i), address(0));
            vm.prank(deployer);
            res.approveOracle(uint16(101 + i), o[i]);
        }
        vm.startPrank(deployer);
        OracleCouncil council = new OracleCouncil(res);
        res.transferOwnership(address(council));
        vm.stopPrank();
        vm.resumeGasMetering();

        uint16 subject = uint16(101 + c - 1); // آخرین کشور؛ رأی نمیدهد
        uint256 total;
        vm.prank(o[0]);
        uint256 id = council.propose(abi.encodeCall(RESNFT.suspend, (subject)));
        uint256 g = vm.lastCallGas().gasTotalUsed;
        _log(c, "propose", g);
        total += g;
        uint256 votes = 1;
        for (uint256 i = 1; !res.suspended(subject); ++i) {
            vm.prank(o[i]);
            council.vote(id);
            g = vm.lastCallGas().gasTotalUsed;
            if (i == 1) _log(c, "vote_first", g);
            total += g;
            ++votes;
            if (res.suspended(subject)) _log(c, "vote_exec", g);
        }
        assertEq(votes * 3 >= (c - 1) * 2, true, "threshold");
        _log(c, "votes", votes);
        _log(c, "total", total);
    }
}
