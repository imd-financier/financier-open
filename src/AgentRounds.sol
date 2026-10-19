// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

interface IAgentMiningVault {
    function epoch() external view returns (uint256);
    function genesis() external view returns (uint256);
    function EMISSION_END() external view returns (uint256);
    function agentAllocation(uint256 fromElapsed, uint256 toElapsed) external view returns (uint256);
    function payAgentReward(address beneficiary, uint256 amount) external;
}

/// @notice Bounded disjoint rounds, immutable complete-set proof boundary and independent pull claims.
/// No authority may reassign dust, empty/expired budgets or unearned rewards.
contract AgentRounds is ReentrancyGuard {
    uint256 public constant MAX_AGENTS = 32;
    uint256 public constant MAX_PROOF_BYTES = 16384;
    uint256 public constant VERIFICATION_GAS = 1_000_000;
    IAgentMiningVault public immutable vault;
    IAgentWorkVerifier public immutable verifier;
    bytes32 public immutable verifierCodeHash;
    bytes32 public immutable policyHash;
    uint256 public immutable roundSeconds;
    uint256 public immutable graceSeconds;
    uint256 public immutable identityMaxAge;
    uint256 public totalFinalizedBudget;
    uint256 public totalAllocated;
    uint256 public totalPaid;
    uint256 public totalQuarantined;

    struct Round {
        bool finalized;
        uint256 budget;
        uint256 count;
        uint256 share;
        uint256 paid;
        bytes32 commitment;
    }
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => uint256)) public claimable;
    mapping(bytes32 => bool) public usedReceipt;
    mapping(bytes32 => bool) public usedSubmission;
    mapping(bytes32 => bool) public usedArtifact;
    mapping(bytes32 => uint256) public jobRoundPlusOne;
    error BadConfiguration();
    error NotStarted();
    error InvalidRound();
    error WrongTime();
    error AlreadyFinalized();
    error UnverifiedWork();
    error InvalidContribution();
    error Duplicate();
    error NoClaim();
    event RoundFinalized(
        uint256 indexed roundId,
        bytes32 indexed commitment,
        uint256 budget,
        uint256 count,
        uint256 share,
        uint256 quarantined
    );
    event AgentAccepted(
        uint256 indexed roundId,
        bytes32 indexed identity,
        address indexed beneficiary,
        bytes32 jobId,
        bytes32 receiptId,
        bytes32 submissionHash,
        bytes32 artifactHash
    );
    event AgentClaimed(uint256 indexed roundId, address indexed beneficiary, uint256 amount);

    constructor(address vault_, address verifier_, bytes32 policy_, uint256 seconds_, uint256 grace_, uint256 maxAge_) {
        // The vault constructs this module; its runtime is not installed until its constructor returns.
        if (
            vault_ == address(0) || verifier_.code.length == 0 || policy_ == 0 || seconds_ < 1 hours
                || seconds_ > 30 days || grace_ == 0 || grace_ > 30 days || maxAge_ == 0 || maxAge_ > 1 days
        ) revert BadConfiguration();
        vault = IAgentMiningVault(vault_);
        verifier = IAgentWorkVerifier(verifier_);
        verifierCodeHash = verifier_.codehash;
        policyHash = policy_;
        roundSeconds = seconds_;
        graceSeconds = grace_;
        identityMaxAge = maxAge_;
    }

    function context(uint256 id) public view returns (IAgentWorkVerifier.Context memory c) {
        if (vault.epoch() == 0) revert NotStarted();
        uint256 horizon = vault.EMISSION_END();
        if (id >= (horizon + roundSeconds - 1) / roundSeconds) revert InvalidRound();
        uint256 start = id * roundSeconds;
        uint256 end = start + roundSeconds;
        if (end > horizon) end = horizon;
        uint256 g = vault.genesis();
        c = IAgentWorkVerifier.Context(
            block.chainid, address(vault), address(this), policyHash, id, g + start, g + end, g + end + graceSeconds
        );
    }

    function identity(IAgentWorkVerifier.Contribution memory a) public pure returns (bytes32) {
        return keccak256(abi.encode(a.sourceChain, a.identityRegistry, a.agentId));
    }

    function commitment(IAgentWorkVerifier.Context memory c, IAgentWorkVerifier.Contribution[] memory a)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(c, a));
    }

    function _budget(IAgentWorkVerifier.Context memory c) private view returns (uint256) {
        uint256 g = vault.genesis();
        return vault.agentAllocation(c.start - g, c.end - g);
    }

    function finalize(uint256 id, IAgentWorkVerifier.Contribution[] calldata accepted, bytes calldata proof)
        external
        nonReentrant
    {
        IAgentWorkVerifier.Context memory c = context(id);
        if (rounds[id].finalized) revert AlreadyFinalized();
        if (block.timestamp < c.end || block.timestamp > c.deadline) revert WrongTime();
        if (
            accepted.length > MAX_AGENTS || proof.length > MAX_PROOF_BYTES
                || address(verifier).codehash != verifierCodeHash
        ) revert UnverifiedWork();
        bytes32 digest = commitment(c, accepted);
        // View call, bounded gas, no copied arbitrary reward signer. Errors fail closed.
        try verifier.verifyCompleteRound{gas: VERIFICATION_GAS}(c, accepted, proof) returns (bytes32 verified) {
            if (verified != digest) revert UnverifiedWork();
        } catch {
            revert UnverifiedWork();
        }
        uint256 n = accepted.length;
        for (uint256 i; i < n; ++i) {
            IAgentWorkVerifier.Contribution memory a = accepted[i];
            if (
                a.sourceChain == 0 || a.identityRegistry == address(0) || a.controller == address(0)
                    || a.beneficiary != a.controller || a.jobId == 0 || a.receiptId == 0 || a.submissionHash == 0
                    || a.artifactHash == 0 || a.completedAt < c.start || a.completedAt >= c.end
                    || a.identityObservedAt > block.timestamp || block.timestamp - a.identityObservedAt > identityMaxAge
                    || a.identityExpiresAt < block.timestamp || a.identityExpiresAt < a.identityObservedAt
                    || a.identityExpiresAt - a.identityObservedAt > identityMaxAge
            ) revert InvalidContribution();
            if (
                usedReceipt[a.receiptId] || usedSubmission[a.submissionHash] || usedArtifact[a.artifactHash]
                    || (jobRoundPlusOne[a.jobId] != 0 && jobRoundPlusOne[a.jobId] != id + 1)
            ) revert Duplicate();
            for (uint256 j; j < i; ++j) {
                if (identity(accepted[j]) == identity(a) || accepted[j].controller == a.controller) revert Duplicate();
            }
            usedReceipt[a.receiptId] = true;
            usedSubmission[a.submissionHash] = true;
            usedArtifact[a.artifactHash] = true;
            jobRoundPlusOne[a.jobId] = id + 1;
        }
        uint256 budget = _budget(c);
        uint256 share = n == 0 ? 0 : budget / n;
        uint256 allocated = share * n;
        rounds[id] = Round(true, budget, n, share, 0, digest);
        totalFinalizedBudget += budget;
        totalAllocated += allocated;
        totalQuarantined += budget - allocated;
        for (uint256 i; i < n; ++i) {
            IAgentWorkVerifier.Contribution memory a = accepted[i];
            claimable[id][a.beneficiary] = share;
            emit AgentAccepted(id, identity(a), a.beneficiary, a.jobId, a.receiptId, a.submissionHash, a.artifactHash);
        }
        emit RoundFinalized(id, digest, budget, n, share, budget - allocated);
    }

    /// @notice After grace, anyone may close a missing/unverifiable round without paying anyone.
    function expire(uint256 id) external nonReentrant {
        IAgentWorkVerifier.Context memory c = context(id);
        if (rounds[id].finalized) revert AlreadyFinalized();
        if (block.timestamp <= c.deadline) revert WrongTime();
        uint256 budget = _budget(c);
        rounds[id] = Round(true, budget, 0, 0, 0, 0);
        totalFinalizedBudget += budget;
        totalQuarantined += budget;
        emit RoundFinalized(id, 0, budget, 0, 0, budget);
    }

    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        if (!rounds[id].finalized) revert NoClaim();
        amount = claimable[id][msg.sender];
        if (amount == 0) revert NoClaim();
        claimable[id][msg.sender] = 0;
        rounds[id].paid += amount;
        totalPaid += amount;
        vault.payAgentReward(msg.sender, amount);
        emit AgentClaimed(id, msg.sender, amount);
    }
}
