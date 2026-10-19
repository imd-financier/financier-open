// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AttestedAgentRounds} from "./AttestedAgentRounds.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface INativeJobMining {
    function iFinancier() external view returns (address);
    function epoch() external view returns (uint256);
    function agentRounds() external view returns (AttestedAgentRounds);
    function dispatchWork(uint256 round, bytes calldata body) external returns (bytes32);
}

/// @notice Immutable, deterministic work categories; NO recipient-set publishing or finalization method.
/// @dev Its authority slot in AttestedAgentRounds authorizes scope/dispatch ONLY. Unsupported
/// settlement remains unreachable. Completion hashes do not authorize agent rewards.
contract RobinhoodJobController {
    INativeJobMining public immutable miner;
    bytes32 public constant SPECIFICATION = keccak256("FINANCIER_RH_WORK_V1:accepted FINANCIER work only; no payout without authenticated exhaustive agent-wallet statement");
    error Unauthorized();
    error InvalidCategory();

    constructor(address miner_) { miner = INativeJobMining(miner_); }

    function body(uint256 round, uint256 category) public pure returns (bytes memory) {
        string memory work;
        if (category == 0) work = "Research FINANCIER mining economics and auction risks using public evidence.";
        else if (category == 1) work = "Review FINANCIER protocol accounting and security using public evidence.";
        else if (category == 2) work = "Research useful FINANCIER growth and integration opportunities using public evidence.";
        else revert InvalidCategory();
        return abi.encodePacked('{"github":false,"objective":"', work, ' FINANCIER reward period ', Strings.toString(round), '. Read-only report; no payments, signatures, deployments or third-party contact.","skill":"research-report","outputs":[{"name":"report","path":"artifacts/report.md","mediaType":"text/markdown"}]}');
    }

    /// Anyone may prepare a future period's fixed scope; nobody can substitute a different body.
    function prepareRound(uint256 round) public {
        AttestedAgentRounds rounds = miner.agentRounds();
        (bool committed,) = rounds.scopes(round);
        if (committed) return;
        bytes32[] memory hashes = new bytes32[](3);
        for (uint256 i; i < 3; ++i) hashes[i] = keccak256(body(round, i));
        rounds.precommitRound(round, hashes, SPECIFICATION);
    }

    /// Current financier selects a category; the vault, not the browser or this controller, pays Intake.
    function commission(uint256 round, uint256 category) external returns (bytes32) {
        if (miner.epoch() == 0 || msg.sender != miner.iFinancier()) revert Unauthorized();
        return miner.dispatchWork(round, body(round, category));
    }
}
