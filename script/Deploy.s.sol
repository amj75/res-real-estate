// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/OracleCouncil.sol";
import "../contracts/RESNFT.sol";

// مرجع پرونده ثبتی آزمایشی (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
bytes32 constant SEED_CASE = keccak256("RES demo seed");

/// Deploy الگوی UUPS: پیاده‌سازی + پروکسی — آدرس پروکسی همان قرارداد کاربر است
contract Deploy is Script {
    function run() external {
        // اوراکل = دیپلویر (کلید برودکست)؛ ولت‌های اضافی از env اختیاری: ELIGIBLE_1, ELIGIBLE_2,...
        address oracle = vm.envAddress("DEPLOYER");
        uint16 country = uint16(vm.envOr("COUNTRY", uint256(364))); // کد عددی ISO 3166 (پیش‌فرض: ایران)
        address[] memory extra = new address[](0); // ponytail: envOr در forge-std قدیمی نیست؛ ولت اضافی بعداً از UI add میشود
        vm.startBroadcast();
        RESNFT impl = new RESNFT();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(RESNFT.initialize, (country))
        );
        RESNFT res = RESNFT(payable(address(proxy)));

        res.addToEligibleList(oracle, SEED_CASE);
        for (uint256 i; i < extra.length; ++i) res.addToEligibleList(extra[i], SEED_CASE);

        // دو ملک نمونه: 100 و 50 ETH، mint به اوراکل
        res.addAsset(100 ether, oracle, SEED_CASE);
        res.addAsset(50 ether, oracle, SEED_CASE);

        console.log("RESNFT impl:   ", address(impl));
        console.log("RESNFT proxy:  ", address(proxy));
        console.log("oracle:", oracle);
        vm.stopBroadcast();
    }
}

/// ارتقا: نسخه جدید را دیپلوی کن و upgradeToAndCall بزن — از پروکسی، با کلید owner
/// ارتقای v3 → v4 باید initializeV2(country) را صدا بزند (Pausable + اوراکل فعلی = اوراکل کشور country)
contract Upgrade is Script {
    function run() external {
        address proxyAddr = vm.envAddress("PROXY");
        bool fromV3 = vm.envOr("FROM_V3", false);
        uint16 country = uint16(vm.envOr("COUNTRY", uint256(364)));
        vm.startBroadcast();
        RESNFT newImpl = new RESNFT();
        RESNFT(payable(proxyAddr)).upgradeToAndCall(
            address(newImpl), fromV3 ? abi.encodeCall(RESNFT.initializeV2, (country)) : bytes("")
        );
        console.log("upgraded to:", address(newImpl));
        vm.stopBroadcast();
    }
}

/// فدراسیون (راه‌اندازی اعضای مؤسس): اوراکل هر کشور = multisig (Safe) مرجع ثبت همان کشور.
/// پیش از اجرا، هر Safe خودش requestOracle(country, guardian) را فرستاده است و اصالت/امنیت آن خارج از
/// زنجیره بررسی شده؛ این اسکریپت (مالک موقت) آن درخواست‌ها را تأیید و مالکیت را به OracleCouncil (DAO)
/// منتقل میکند. از این پس عضویت و تعویض فقط با رأی ۲/۳ DAO.
/// env: PROXY, COUNTRIES (کدهای ISO با کاما), COUNTRY_ORACLES (آدرس Safe هر کشور، به همان ترتیب)
contract Federation is Script {
    function run() external {
        RESNFT res = RESNFT(payable(vm.envAddress("PROXY")));
        uint256[] memory cs = vm.envOr("COUNTRIES", ",", new uint256[](0));
        address[] memory os = vm.envOr("COUNTRY_ORACLES", ",", new address[](0));
        require(cs.length == os.length, "env length mismatch");

        vm.startBroadcast();
        for (uint256 i; i < cs.length; ++i) {
            require(os[i].code.length > 0, "oracle must be a multisig contract");
            res.approveOracle(uint16(cs[i]), os[i]);
        }
        OracleCouncil council = new OracleCouncil(res);
        res.transferOwnership(address(council));
        vm.stopBroadcast();

        console.log("council:", address(council));
    }
}
