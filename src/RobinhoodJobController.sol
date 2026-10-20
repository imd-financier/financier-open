// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AttestedAgentRounds} from "./AttestedAgentRounds.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface INativeJobMining {
    function initializer() external view returns (address);
    function jobs() external view returns (RobinhoodJobController);
    function iFinancier() external view returns (address);
    function epoch() external view returns (uint256);
    function agentRounds() external view returns (AttestedAgentRounds);
    function dispatchWork(uint256 round, bytes calldata body) external returns (bytes32);
    function completions(bytes32 id) external view returns (bool, uint8, bytes32, bytes32);
}

/// @notice One immutable designated publisher. No token custody, arbitrary call, role rotation or withdrawal.
/// @dev A dishonest publisher CAN omit/invent accepted work or lie about Ethereum ownership.
/// Only membership/ownership truth is trusted; on-chain job, budget and timing checks remain mandatory.
contract RobinhoodJobController {
    address public immutable initializer;
    address public immutable publisher;
    INativeJobMining public miner;
    bytes32 public constant SPECIFICATION = keccak256(
        "FINANCIER_SEAT_OWNER_V1:founder-evidence-relay;accepted-nonempty-FINANCIER-work;distinct-agent-seat;EOA-owner-at-fixed-finalized-ETH-cutoff;no-redirect;quarantine"
    );
    mapping(uint256 => bytes32) public snapshotDigest;
    mapping(uint256 => bytes32[]) private boundJobs;
    mapping(uint256 => bytes32[]) private purchasedRequests;
    mapping(bytes32 => bytes32) public jobRequest;
    error Unauthorized();
    error InvalidBinding();
    error InvalidSettlement();
    event MinerBound(address indexed miner);
    event SnapshotLocked(uint256 indexed round, bytes32 digest, uint256 sourceBlock, bytes32 sourceBlockHash);

    constructor(address publisher_) {
        if (block.chainid != 4663 || publisher_ == address(0)) revert InvalidBinding();
        initializer = msg.sender;
        publisher = publisher_;
    }

    /// One-shot canonical binding BEFORE funding/activation; founder verifies exact deployed code off-chain.
    function bindMiner(INativeJobMining candidate) external {
        if (msg.sender != initializer) revert Unauthorized();
        if (
            address(miner) != address(0) || address(candidate).code.length == 0
                || candidate.initializer() != initializer || address(candidate.jobs()) != address(this)
                || candidate.epoch() != 0 || candidate.agentRounds().settlementAuthority() != address(this)
                || candidate.agentRounds().policyHash() != SPECIFICATION
        ) revert InvalidBinding();
        miner = candidate;
        emit MinerBound(address(candidate));
    }

    function body(uint256 round, uint256 category) public pure returns (bytes memory) {
        string memory work;
        if (category == 0) {
            work = "Research FINANCIER mining economics and auction risks using public evidence.";
        } else if (category == 1) {
            work = "Review FINANCIER protocol accounting and security using public evidence.";
        } else if (category == 2) {
            work = "Research useful FINANCIER growth and integration opportunities using public evidence.";
        } else {
            revert InvalidBinding();
        }
        return abi.encodePacked(
            '{"github":false,"objective":"',
            work,
            " FINANCIER reward period ",
            Strings.toString(round),
            '. Read-only report; no payments, signatures, deployments or third-party contact.","skill":"research-report","outputs":[{"name":"report","path":"artifacts/report.md","mediaType":"text/markdown"}]}'
        );
    }

    /// Public automation can only precommit these fixed future bodies; no settlement permission.
    function prepareRound(uint256 round) public {
        AttestedAgentRounds rounds = miner.agentRounds();
        (bool committed,) = rounds.scopes(round);
        if (committed) return;
        bytes32[] memory hashes = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            hashes[i] = keccak256(body(round, i));
        }
        rounds.precommitRound(round, hashes, SPECIFICATION);
    }

    function requestIds(uint256 round) external view returns (bytes32[] memory) {
        return purchasedRequests[round];
    }

    /// Work purchase remains current-financier-selected, not a publisher spending privilege.
    function commission(uint256 round, uint256 category) external returns (bytes32) {
        if (miner.epoch() == 0 || msg.sender != miner.iFinancier()) revert Unauthorized();
        bytes32 request = miner.dispatchWork(round, body(round, category));
        purchasedRequests[round].push(request);
        return request;
    }

    /// Attests ONLY backend request-to-UUID admission. Vault records independently bind payer/body/period.
    function bindJob(uint256 round, AttestedAgentRounds.Admission calldata admission) external {
        if (msg.sender != publisher) revert Unauthorized();
        if (jobRequest[admission.jobId] != 0) revert InvalidBinding();
        miner.agentRounds().bindJob(round, admission);
        jobRequest[admission.jobId] = admission.requestId;
        boundJobs[round].push(admission.jobId); // at most three prospectively fixed body slots.
    }

    /// Freeze one source cutoff. Publisher must retain finalized Ethereum header/ownerOf/code evidence.
    function lockSnapshot(uint256 round, AttestedAgentRounds.Snapshot calldata s) external {
        if (msg.sender != publisher) revert Unauthorized();
        IAgentWorkVerifier.Context memory c = miner.agentRounds().context(round);
        if (
            snapshotDigest[round] != 0 || block.timestamp < c.end || block.timestamp > c.deadline || s.blockNumber == 0
                || s.blockHash == 0 || s.timestamp == 0 || s.timestamp > c.end
                || c.end - s.timestamp > miner.agentRounds().identityMaxAge() || s.ownershipEvidenceHash == 0
                || s.acceptedSetEvidenceHash == 0
        ) revert InvalidSettlement();
        snapshotDigest[round] = keccak256(abi.encode(s));
        emit SnapshotLocked(round, snapshotDigest[round], s.blockNumber, s.blockHash);
    }

    function finalizeRound(
        uint256 round,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        AttestedAgentRounds.Snapshot calldata snapshot,
        AttestedAgentRounds.OwnerEvidence[] calldata owners,
        bytes32 expectedCommitment
    ) external {
        if (msg.sender != publisher) revert Unauthorized();
        if (snapshotDigest[round] == 0 || snapshotDigest[round] != keccak256(abi.encode(snapshot))) {
            revert InvalidSettlement();
        }
        bytes32[] storage jobs = boundJobs[round];
        if (jobs.length == 0) revert InvalidSettlement();
        // Even a commissioned request omitted from backend admission cannot be silently ignored.
        bytes32[] storage purchased = purchasedRequests[round];
        for (uint256 i; i < purchased.length; ++i) {
            (bool recorded,,,) = miner.completions(purchased[i]);
            if (!recorded || miner.agentRounds().requestRoundPlusOne(purchased[i]) != round + 1) {
                revert InvalidSettlement();
            }
        }
        // All registered jobs must be closed, including failures; no still-running job can be ignored.
        for (uint256 i; i < jobs.length; ++i) {
            (bool recorded,,,) = miner.completions(jobRequest[jobs[i]]);
            if (!recorded) revert InvalidSettlement();
        }
        for (uint256 i; i < accepted.length; ++i) {
            bytes32 request = jobRequest[accepted[i].jobId];
            (bool recorded, uint8 status, bytes32 result,) = miner.completions(request);
            if (!recorded || status != 0 || result == 0) revert InvalidSettlement();
        }
        miner.agentRounds().finalize(round, accepted, snapshot, owners, expectedCommitment);
    }
}
