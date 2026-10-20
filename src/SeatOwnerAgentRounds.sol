// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AttestedAgentRounds} from "./AttestedAgentRounds.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

/// @notice Single-attester candidate: one share per distinct canonical agent/seat, aggregated by NFT owner.
/// @dev Ethereum ownership, acceptance and completeness are TRUSTED attestations, not Robinhood state proofs.
contract SeatOwnerAgentRounds is AttestedAgentRounds {
    mapping(uint256 => mapping(address => bool)) private walletListed;

    constructor(address vault_, address authority_, bytes32 policy_, uint256 seconds_, uint256 grace_, uint256 maxAge_)
        AttestedAgentRounds(vault_, authority_, policy_, seconds_, grace_, maxAge_)
    {}

    function _artifactReuseKey(IAgentWorkVerifier.Contribution memory a) internal pure override returns (bytes32) {
        // Content equality across different accepted agents is not identity duplication.
        // Do not include job, period, seat or owner: none may reset the same agent's reuse guard.
        return keccak256(abi.encode(keccak256("FINANCIER_TASK28_ARTIFACT_REUSE_V1"), identity(a), a.artifactHash));
    }

    function _duplicateOwner(
        IAgentWorkVerifier.Contribution memory,
        IAgentWorkVerifier.Contribution memory,
        OwnerEvidence memory previous,
        OwnerEvidence memory current
    ) internal pure override returns (bool) {
        return previous.nftId == current.nftId; // identity duplicates remain rejected by the base.
    }

    event UnsupportedOwnerQuarantined(uint256 indexed round, bytes32 indexed agent, address owner, uint256 share);

    function _validatePayout(IAgentWorkVerifier.Contribution memory a, OwnerEvidence memory o) internal pure override {
        // Exactly the source NFT holder, with no payout redirect or registration.
        if (a.beneficiary != a.controller || o.ownerAuthorizationHash != 0 || o.payoutCompatibilityHash != 0) {
            revert InvalidContribution();
        }
    }

    function _credit(uint256 id, IAgentWorkVerifier.Contribution memory a, OwnerEvidence memory o, uint256 share)
        internal
        override
        returns (uint256)
    {
        // Unsupported owners stay in the equal-share denominator, never redistributed to EOAs.
        if (o.sourceOwnerIsContract || a.beneficiary.code.length != 0) {
            emit UnsupportedOwnerQuarantined(id, identity(a), a.controller, share);
            return 0;
        }
        claimable[id][a.beneficiary] += share;
        if (!walletListed[id][a.beneficiary]) {
            walletListed[id][a.beneficiary] = true;
            beneficiaries[id].push(a.beneficiary);
        }
        emit OwnershipAttested(id, identity(a), a.agentId, o.nftId, a.controller, a.beneficiary, false, 0, 0);
        emit AgentAccepted(id, identity(a), a.beneficiary, a.jobId, a.receiptId, a.submissionHash, a.artifactHash);
        return share;
    }

    function _beforeClaim() internal view override {
        if (msg.sender.code.length != 0) revert InvalidContribution();
    }
}
