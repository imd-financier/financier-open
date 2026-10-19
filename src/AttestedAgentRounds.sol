// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

interface IAttestedMiningVault {
    function epoch() external view returns (uint256);
    function genesis() external view returns (uint256);
    function EMISSION_END() external view returns (uint256);
    function agentAllocation(uint256 fromElapsed, uint256 toElapsed) external view returns (uint256);
    function payAgentReward(address beneficiary, uint256 amount) external;
    function workRequests(bytes32 id)
        external
        view
        returns (uint256 roundPlusOne, bytes32 bodyHash, uint256 requestedAt);
}

/// @notice Authority-attested owner-wallet rounds. Truth/completeness are TRUSTED, not cryptographically proved.
/// No authority may reassign dust, empty/expired budgets or unearned rewards.
contract AttestedAgentRounds is ReentrancyGuard {
    uint256 public constant MAX_AGENTS = 32;
    IAttestedMiningVault public immutable vault;
    address public immutable settlementAuthority;
    uint256 public constant SOURCE_CHAIN = 1;
    address public constant IDENTITY_REGISTRY = address(bytes20(hex"8004a169fb4a3325136eb29fa0ceb6d2e539a432"));
    address public constant NFT_COLLECTION = address(bytes20(hex"0000ec93127baa929e58e97dd0095a2bfb38ec1d"));
    address public constant IMD_ADAPTER = address(bytes20(hex"de152afb7db5373f34876e1499fbd893a82dd336"));
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
    mapping(bytes32 => bool) public usedOwnerAuthorization;
    mapping(bytes32 => bool) public usedReceipt;
    mapping(bytes32 => bool) public usedSubmission;
    mapping(bytes32 => bool) public usedArtifact;
    mapping(bytes32 => uint256) public jobRoundPlusOne;
    error BadConfiguration();
    error NotStarted();
    error InvalidRound();
    error WrongTime();
    error AlreadyFinalized();
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

    constructor(
        address vault_,
        address authority_,
        bytes32 policy_,
        uint256 seconds_,
        uint256 grace_,
        uint256 maxAge_
    ) {
        // The vault constructs this module; its runtime is not installed until its constructor returns.
        if (
            vault_ == address(0) || authority_ == address(0) || authority_ == vault_ || authority_ == address(this)
                || policy_ == 0 || seconds_ < 1 hours || seconds_ > 30 days || grace_ == 0 || grace_ > 30 days
                || maxAge_ == 0 || maxAge_ > 1 days
        ) revert BadConfiguration();
        vault = IAttestedMiningVault(vault_);
        settlementAuthority = authority_;
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

    function _budget(IAgentWorkVerifier.Context memory c) private view returns (uint256) {
        uint256 g = vault.genesis();
        return vault.agentAllocation(c.start - g, c.end - g);
    }

    /// @dev Snapshot is the latest finalized Ethereum block at/before the end cutoff,
    /// within identityMaxAge. Authority attests finality/ownerOf, mapping and completeness.
    struct Snapshot {
        uint256 blockNumber;
        bytes32 blockHash;
        uint256 timestamp;
        bytes32 ownershipEvidenceHash;
        bytes32 acceptedSetEvidenceHash;
    }

    struct OwnerEvidence {
        uint256 nftId;
        bool sourceOwnerIsContract;
        bytes32 ownerAuthorizationHash;
        bytes32 payoutCompatibilityHash;
        uint256 submittedAt; // Official source submission time; authority-attested, not block.timestamp.
    }

    struct Scope {
        bool committed;
        bytes32 commitment;
    }
    mapping(uint256 => Scope) public scopes;
    mapping(uint256 => mapping(bytes32 => bool)) public permittedJob;
    mapping(uint256 => mapping(bytes32 => bool)) public permittedRequestBody;
    mapping(uint256 => mapping(bytes32 => bool)) public boundRequestBody;
    mapping(bytes32 => uint256) public requestRoundPlusOne;
    mapping(bytes32 => uint256) public jobBoundAt;
    mapping(uint256 => bytes32) public jobBindingsCommitment;

    struct Admission {
        bytes32 requestId;
        bytes32 jobId;
        bytes32 requestBodyHash;
        uint256 requestedAt;
        uint256 admittedAt;
        bytes32 evidenceHash;
    }
    mapping(uint256 => address[]) public beneficiaries;
    error Unauthorized();
    error ScopeUnavailable();
    error BadSnapshot();
    error BadCommitment();
    error UnrecordedDispatch();
    event RequestBodyPrecommitted(uint256 indexed roundId, bytes32 indexed requestBodyHash);
    event JobBound(
        uint256 indexed roundId,
        bytes32 indexed jobId,
        bytes32 indexed requestId,
        bytes32 requestBodyHash,
        uint256 requestedAt,
        uint256 admittedAt,
        uint256 boundAt,
        uint256 boundBlock,
        bytes32 evidenceHash
    );
    event ScopePrecommitted(uint256 indexed roundId, bytes32 indexed commitment, bytes32 specificationHash);
    event OwnershipAttested(
        uint256 indexed roundId,
        bytes32 indexed identity,
        uint256 agentId,
        uint256 nftId,
        address owner,
        address beneficiary,
        bool sourceOwnerIsContract,
        bytes32 ownerAuthorizationHash,
        bytes32 payoutCompatibilityHash
    );
    event EvidenceAttested(
        uint256 indexed roundId,
        uint256 sourceBlock,
        bytes32 sourceBlockHash,
        uint256 sourceTimestamp,
        bytes32 ownershipEvidenceHash,
        bytes32 acceptedSetEvidenceHash
    );

    /// @notice Freeze exact FINANCIER request bodies and acceptance/request policy BEFORE
    /// the window. No future Intake request ID or backend job UUID is guessed here.
    function precommitRound(uint256 id, bytes32[] calldata requestBodyHashes, bytes32 specificationHash) external {
        if (msg.sender != settlementAuthority) revert Unauthorized();
        uint256 horizon = vault.EMISSION_END();
        if (id >= (horizon + roundSeconds - 1) / roundSeconds) revert InvalidRound();
        if (
            scopes[id].committed || rounds[id].finalized || requestBodyHashes.length == 0
                || requestBodyHashes.length > MAX_AGENTS || specificationHash == 0
        ) revert ScopeUnavailable();
        if (vault.epoch() != 0 && block.timestamp >= vault.genesis() + id * roundSeconds) revert WrongTime();
        for (uint256 i; i < requestBodyHashes.length; ++i) {
            bytes32 body = requestBodyHashes[i];
            if (body == 0 || permittedRequestBody[id][body]) revert Duplicate();
            permittedRequestBody[id][body] = true;
            emit RequestBodyPrecommitted(id, body);
        }
        bytes32 digest = keccak256(
            abi.encode(
                bytes32("FINANCIER_SCOPE_V2"),
                block.chainid,
                address(vault),
                address(this),
                policyHash,
                id,
                requestBodyHashes,
                specificationHash
            )
        );
        scopes[id] = Scope(true, digest);
        emit ScopePrecommitted(id, digest, specificationHash);
    }

    /// @notice Bind actual paid request/admitted job while the window is OPEN, before any
    /// eligible submission. Vault-recorded request/body/time MUST match; authority still
    /// attests backend job mapping/admission and absence of existing source submissions.
    function bindJob(uint256 id, Admission calldata a) external {
        if (msg.sender != settlementAuthority) revert Unauthorized();
        IAgentWorkVerifier.Context memory c = context(id);
        if (!scopes[id].committed || rounds[id].finalized) revert ScopeUnavailable();
        if (block.timestamp < c.start || block.timestamp >= c.end) revert WrongTime();
        if (!permittedRequestBody[id][a.requestBodyHash] || a.requestId == 0 || a.jobId == 0 || a.evidenceHash == 0) {
            revert InvalidContribution();
        }
        if (a.requestedAt < c.start || a.admittedAt < a.requestedAt || a.admittedAt > block.timestamp) {
            revert WrongTime();
        }
        if (
            boundRequestBody[id][a.requestBodyHash] || requestRoundPlusOne[a.requestId] != 0
                || jobRoundPlusOne[a.jobId] != 0
        ) revert Duplicate();
        (uint256 dispatchedRound, bytes32 dispatchedHash, uint256 dispatchedAt) = vault.workRequests(a.requestId);
        if (dispatchedRound != id + 1 || dispatchedHash != a.requestBodyHash || dispatchedAt != a.requestedAt) {
            revert UnrecordedDispatch();
        }
        boundRequestBody[id][a.requestBodyHash] = true;
        requestRoundPlusOne[a.requestId] = id + 1;
        jobRoundPlusOne[a.jobId] = id + 1;
        jobBoundAt[a.jobId] = block.timestamp;
        permittedJob[id][a.jobId] = true;
        jobBindingsCommitment[id] = keccak256(abi.encode(jobBindingsCommitment[id], a, block.timestamp, block.number));
        emit JobBound(
            id,
            a.jobId,
            a.requestId,
            a.requestBodyHash,
            a.requestedAt,
            a.admittedAt,
            block.timestamp,
            block.number,
            a.evidenceHash
        );
    }

    function settlementCommitment(
        uint256 id,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        Snapshot calldata snapshot,
        OwnerEvidence[] calldata owners
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(context(id), scopes[id].commitment, jobBindingsCommitment[id], accepted, snapshot, owners)
        );
    }

    /// @notice This explicit authority, NOT a generic oracle, attests the complete accepted
    /// FINANCIER list and ownership/consent evidence. A dishonest authority can misdirect
    /// this round's agent allocation; it cannot touch the financier stream or other buckets.
    function finalize(
        uint256 id,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        Snapshot calldata snapshot,
        OwnerEvidence[] calldata owners,
        bytes32 expectedCommitment
    ) external nonReentrant {
        if (msg.sender != settlementAuthority) revert Unauthorized();
        IAgentWorkVerifier.Context memory c = context(id);
        if (rounds[id].finalized) revert AlreadyFinalized();
        if (!scopes[id].committed) revert ScopeUnavailable();
        if (block.timestamp < c.end || block.timestamp > c.deadline) revert WrongTime();
        if (accepted.length > MAX_AGENTS || owners.length != accepted.length) revert InvalidContribution();
        if (
            snapshot.blockNumber == 0 || snapshot.blockHash == 0 || snapshot.timestamp == 0
                || snapshot.timestamp > c.end || c.end - snapshot.timestamp > identityMaxAge
                || snapshot.ownershipEvidenceHash == 0 || snapshot.acceptedSetEvidenceHash == 0
        ) revert BadSnapshot();
        bytes32 digest = settlementCommitment(id, accepted, snapshot, owners);
        if (digest != expectedCommitment) revert BadCommitment();
        _validateAccepted(id, c, accepted, owners, snapshot.timestamp);
        _allocate(id, c, accepted, owners, digest);
        emit EvidenceAttested(
            id,
            snapshot.blockNumber,
            snapshot.blockHash,
            snapshot.timestamp,
            snapshot.ownershipEvidenceHash,
            snapshot.acceptedSetEvidenceHash
        );
    }

    function _validateAccepted(
        uint256 id,
        IAgentWorkVerifier.Context memory c,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        OwnerEvidence[] calldata owners,
        uint256 snapshotTimestamp
    ) private {
        uint256 n = accepted.length;
        for (uint256 i; i < n; ++i) {
            IAgentWorkVerifier.Contribution memory a = accepted[i];
            if (
                a.sourceChain != SOURCE_CHAIN || a.identityRegistry != IDENTITY_REGISTRY || a.controller == address(0)
                    || a.controller == IDENTITY_REGISTRY || a.controller == NFT_COLLECTION
                    || a.controller == IMD_ADAPTER || a.beneficiary == address(0) || a.beneficiary == address(vault)
                    || a.beneficiary == address(this) || a.beneficiary == IMD_ADAPTER
                    || a.beneficiary == IDENTITY_REGISTRY || a.beneficiary == NFT_COLLECTION
                    || !permittedJob[id][a.jobId] || a.receiptId == 0 || a.submissionHash == 0 || a.artifactHash == 0
                    || owners[i].submittedAt <= jobBoundAt[a.jobId] || a.completedAt < owners[i].submittedAt
                    || a.completedAt < c.start || a.completedAt >= c.end || a.identityObservedAt != snapshotTimestamp
                    || a.identityExpiresAt != c.deadline
            ) revert InvalidContribution();
            if (
                usedReceipt[a.receiptId] || usedSubmission[a.submissionHash] || usedArtifact[a.artifactHash]
                    || (jobRoundPlusOne[a.jobId] != 0 && jobRoundPlusOne[a.jobId] != id + 1)
            ) revert Duplicate();
            OwnerEvidence memory o = owners[i];
            if (o.ownerAuthorizationHash != 0) {
                if (usedOwnerAuthorization[o.ownerAuthorizationHash]) revert Duplicate();
                usedOwnerAuthorization[o.ownerAuthorizationHash] = true;
            }
            // Authority must retain signed/destination/round-bound consent evidence for redirects.
            if (a.beneficiary != a.controller && o.ownerAuthorizationHash == 0) revert InvalidContribution();
            // A source contract at the same address must actually exist on Robinhood and
            // have a reviewed claim path; otherwise use an owner-authorized compatible wallet.
            if (a.beneficiary.code.length != 0 || (o.sourceOwnerIsContract && a.beneficiary == a.controller)) {
                if (a.beneficiary.code.length == 0 || o.payoutCompatibilityHash == 0) revert InvalidContribution();
            }
            for (uint256 j; j < i; ++j) {
                if (
                    identity(accepted[j]) == identity(a) || accepted[j].controller == a.controller
                        || accepted[j].beneficiary == a.beneficiary || owners[j].nftId == o.nftId
                ) revert Duplicate();
            }
            usedReceipt[a.receiptId] = true;
            usedSubmission[a.submissionHash] = true;
            usedArtifact[a.artifactHash] = true;
            jobRoundPlusOne[a.jobId] = id + 1;
        }
    }

    function _allocate(
        uint256 id,
        IAgentWorkVerifier.Context memory c,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        OwnerEvidence[] calldata owners,
        bytes32 digest
    ) private {
        uint256 n = accepted.length;
        uint256 budget = _budget(c);
        uint256 share = n == 0 ? 0 : budget / n;
        uint256 allocated = share * n;
        rounds[id] = Round(true, budget, n, share, 0, digest);
        totalFinalizedBudget += budget;
        totalAllocated += allocated;
        totalQuarantined += budget - allocated;
        for (uint256 i; i < n; ++i) {
            _credit(id, accepted[i], owners[i], share);
        }
        emit RoundFinalized(id, digest, budget, n, share, budget - allocated);
    }

    function _credit(uint256 id, IAgentWorkVerifier.Contribution memory a, OwnerEvidence memory o, uint256 share)
        private
    {
        claimable[id][a.beneficiary] = share;
        beneficiaries[id].push(a.beneficiary);
        emit OwnershipAttested(
            id,
            identity(a),
            a.agentId,
            o.nftId,
            a.controller,
            a.beneficiary,
            o.sourceOwnerIsContract,
            o.ownerAuthorizationHash,
            o.payoutCompatibilityHash
        );
        emit AgentAccepted(id, identity(a), a.beneficiary, a.jobId, a.receiptId, a.submissionHash, a.artifactHash);
    }

    /// @notice After grace, anyone may close a missing/unsettled round without paying anyone.
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
