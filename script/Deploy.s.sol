// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/RESNFT.sol";

/// Deploy الگوی UUPS: پیاده‌سازی + پروکسی — آدرس پروکسی همان قرارداد کاربر است
contract Deploy is Script {
    function run() external {
        // اوراکل = دیپلویر (کلید برودکست)؛ ولت‌های اضافی از env اختیاری: ELIGIBLE_1, ELIGIBLE_2,...
        address oracle = vm.envAddress("DEPLOYER");
        address[] memory extra = new address[](0); // ponytail: envOr در forge-std قدیمی نیست؛ ولت اضافی بعداً از UI add میشود
        vm.startBroadcast();
        RESNFT impl = new RESNFT();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RESNFT.initialize, ())
        );
        RESNFT res = RESNFT(payable(address(proxy)));

        res.addToEligibleList(oracle);
        for (uint256 i; i < extra.length; ++i) res.addToEligibleList(extra[i]);

        // دو ملک نمونه: 100 و 50 ETH، mint به اوراکل
        res.addAsset(100 ether, oracle);
        res.addAsset(50 ether, oracle);

        console.log("RESNFT impl:   ", address(impl));
        console.log("RESNFT proxy:  ", address(proxy));
        console.log("oracle:", oracle);
        vm.stopBroadcast();
    }
}

/// ارتقا: نسخه جدید را دیپلوی کن و upgradeToAndCall بزن — از پروکسی، با کلید owner
contract Upgrade is Script {
    function run() external {
        address proxyAddr = vm.envAddress("PROXY");
        vm.startBroadcast();
        RESNFT newImpl = new RESNFT();
        RESNFT(payable(proxyAddr)).upgradeToAndCall(address(newImpl), "");
        console.log("upgraded to:", address(newImpl));
        vm.stopBroadcast();
    }
}
