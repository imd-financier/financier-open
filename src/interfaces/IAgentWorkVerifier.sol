// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Security contract for a FUTURE authenticated bridge/parser, not an IMD ABI claim.
/// Must authenticate canonical source commitment, finality, agent/control/consent and authority,
/// exact accepted contribution/artifact and FINANCIER purpose, AND completeness of this round's
/// entire accepted set. Membership alone is insufficient. Return hash of exact context + set.
interface IAgentWorkVerifier {
    struct Context {
        uint256 destinationChain;
        address vault;
        address rounds;
        bytes32 policyHash;
        uint256 roundId;
        uint256 start;
        uint256 end;
        uint256 deadline;
    }

    struct Contribution {
        uint256 sourceChain;
        address identityRegistry;
        uint256 agentId;
        address controller;
        address beneficiary;
        bytes32 jobId;
        bytes32 receiptId;
        bytes32 submissionHash;
        bytes32 artifactHash;
        uint256 completedAt;
        uint256 identityObservedAt;
        uint256 identityExpiresAt;
    }
    function verifyCompleteRound(Context calldata context, Contribution[] calldata accepted, bytes calldata proof)
        external
        view
        returns (bytes32 commitment);
}
