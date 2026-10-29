// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

/// multisig حداقلی k-of-n فقط برای تست — جانشین Safe در استقرار واقعی.
/// امضاکنندگان مجاز مرجع ثبت یک فراخوانی (target, data) را پیشنهاد/تأیید میکنند؛
/// با رسیدن به حد نصاب، خود multisig (= oracleAddress) آن را اجرا میکند.
contract MultisigOracle {
    mapping(address => bool) public isSigner;
    uint256 public threshold;

    struct Call { address target; bytes data; uint256 confirms; bool done; }
    Call[] public calls;
    mapping(uint256 => mapping(address => bool)) public confirmed;

    constructor(address[] memory signers, uint256 k) {
        require(k >= 1 && k <= signers.length, "bad threshold");
        for (uint256 i; i < signers.length; ++i) isSigner[signers[i]] = true;
        threshold = k;
    }

    function submit(address target, bytes calldata data) external returns (uint256 id) {
        require(isSigner[msg.sender], "not signer");
        id = calls.length;
        calls.push(Call(target, data, 0, false));
        confirm(id);
    }

    function confirm(uint256 id) public {
        require(isSigner[msg.sender], "not signer");
        require(!confirmed[id][msg.sender], "already confirmed");
        Call storage c = calls[id];
        require(!c.done, "done");
        confirmed[id][msg.sender] = true;
        if (++c.confirms < threshold) return;
        c.done = true;
        (bool ok, bytes memory ret) = c.target.call(c.data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
