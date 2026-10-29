// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {RESNFT} from "./RESNFT.sol";

/**
 * @title OracleCouncil — DAO کشورها، مالک قرارداد RESNFT
 * هر کشور عضو با آدرس اوراکل خودش (multisig مرجع ثبت آن کشور) یک رأی دارد.
 * هر تصمیم = یک فراخوانی روی RESNFT (تعلیق، پیشنهاد اوراکل/عضو جدید، ارتقا، unpause، ...)
 * و با رأی ۲/۳ اعضای فعال، بلافاصله اجرا میشود.
 * - رأی کشور تعلیق‌شده شمرده نمیشود و نمیتواند پیشنهاد یا رأی بدهد
 * - در تصمیم درباره خود یک کشور (suspend / approveOracle آن کشور) رأی همان کشور شمرده نمیشود،
 *   پس اوراکل لو رفته نمیتواند جلوی تعلیق خودش را بگیرد
 * - آدرس جدید هر کشور را خود کشور با requestOracle درخواست میدهد؛ اعضا خارج از زنجیره اصالت و
 *   امنیت آن را بررسی میکنند و تأیید (approveOracle) با ۲/۳ فوراً اجرا میشود
 */
contract OracleCouncil {
    RESNFT public immutable res;
    uint256 public constant VOTING_PERIOD = 7 days; // پیشنهاد کهنه با ترکیب اعضای بعدی اجرا نشود

    struct Proposal {
        bytes data;        // فراخوانی روی RESNFT
        uint16 subject;    // کشوری که تصمیم درباره آن است (۰ = عمومی)
        uint64 deadline;
        bool executed;
        uint16[] voters;
    }

    Proposal[] private _proposals;
    mapping(uint256 => mapping(uint16 => bool)) public hasVoted;

    event Proposed(uint256 indexed id, uint16 indexed proposer, uint16 subject, bytes data);
    event Voted(uint256 indexed id, uint16 indexed country);
    event Executed(uint256 indexed id);

    constructor(RESNFT r) {
        res = r;
    }

    function propose(bytes calldata data) external returns (uint256 id) {
        uint16 c = _member();
        require(data.length >= 4, "bad data");
        id = _proposals.length;
        Proposal storage p = _proposals.push();
        p.data = data;
        p.subject = _subjectOf(data);
        p.deadline = uint64(block.timestamp + VOTING_PERIOD);
        emit Proposed(id, c, p.subject, data);
        _vote(id, c);
    }

    function vote(uint256 id) external {
        _vote(id, _member());
    }

    function proposal(uint256 id)
        external view returns (bytes memory data, uint16 subject, uint64 deadline, bool executed, uint16[] memory voters)
    {
        Proposal storage p = _proposals[id];
        return (p.data, p.subject, p.deadline, p.executed, p.voters);
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    /// (رأی معتبر، تعداد رأی‌دهنده واجد شرایط) — اجرا وقتی 3 * votes >= 2 * eligible
    function tally(uint256 id) public view returns (uint256 votes, uint256 eligible) {
        Proposal storage p = _proposals[id];
        uint16[] memory cs = res.countries();
        for (uint256 i; i < cs.length; ++i) {
            if (cs[i] != p.subject && !res.suspended(cs[i])) eligible++;
        }
        for (uint256 i; i < p.voters.length; ++i) {
            uint16 v = p.voters[i];
            if (v != p.subject && !res.suspended(v)) votes++;
        }
    }

    function _vote(uint256 id, uint16 c) private {
        Proposal storage p = _proposals[id];
        require(!p.executed, "executed");
        require(block.timestamp <= p.deadline, "expired");
        require(!hasVoted[id][c], "already voted");
        hasVoted[id][c] = true;
        p.voters.push(c);
        emit Voted(id, c);

        (uint256 votes, uint256 eligible) = tally(id);
        if (eligible == 0 || votes * 3 < eligible * 2) return;
        p.executed = true;
        (bool ok, bytes memory ret) = address(res).call(p.data);
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
        emit Executed(id);
    }

    /// عضو فعال = اوراکل فعلی یک کشور که تعلیق نیست
    function _member() private view returns (uint16 c) {
        c = res.countryOf(msg.sender);
        require(c != 0 && !res.suspended(c), "not member");
    }

    /// تصمیم درباره یک کشور خاص: پارامتر اول suspend و approveOracle کشور است
    function _subjectOf(bytes calldata data) private pure returns (uint16) {
        bytes4 sel = bytes4(data[:4]);
        if ((sel == RESNFT.suspend.selector || sel == RESNFT.approveOracle.selector) && data.length >= 36) {
            return uint16(uint256(bytes32(data[4:36])));
        }
        return 0;
    }
}
