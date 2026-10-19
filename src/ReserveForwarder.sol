// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FinancierMining, IInitialSupply} from "./FinancierMining.sol";
import {IIMDProjectFactory, IIMDLaunchRegistry} from "./interfaces/IIMDLaunch.sol";

/// @notice Single-launch immutable literal remainder recipient, with exact code/provenance pins.
/// @dev Actual Robinhood factory/registry prediction and funding flow are locally fork-tested.
/// Production remains NO-GO until official attestation precommit/source admission and all release gates pass.
contract ReserveForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        address factory;
        address registry;
        address deployer;
        bytes32 factoryCodeHash;
        bytes32 registryCodeHash;
        uint64 launchNumber;
        uint256 minerIndex;
        uint256 originalSupply;
        bytes32 provenanceHash;
        bytes32 tokenInitHash;
        bytes32 minerInitHash;
        bytes32 tokenRuntimeHash;
        bytes32 minerRuntimeHash;
        bytes32 minerConfigHash;
    }
    IIMDProjectFactory public immutable factory;
    IIMDLaunchRegistry public immutable registry;
    address public immutable deployer;
    uint256 public immutable destinationChain;
    bytes32 public immutable factoryCodeHash;
    bytes32 public immutable registryCodeHash;
    uint64 public immutable launchNumber;
    uint256 public immutable minerIndex;
    uint256 public immutable originalSupply;
    uint256 public immutable reserve;
    bytes32 public immutable provenanceHash;
    bytes32 public immutable tokenInitHash;
    bytes32 public immutable minerInitHash;
    bytes32 public immutable tokenRuntimeHash;
    bytes32 public immutable minerRuntimeHash;
    bytes32 public immutable minerConfigHash;
    bool public forwarded;
    error InvalidPins();
    error WrongAuthority();
    error WrongLaunch();
    error WrongCreationCode();
    error WrongArtifact();
    error WrongTarget();
    error MissingReserve();
    error InexactForward();
    error AlreadyForwarded();
    event ReserveForwarded(
        uint64 indexed launchNumber,
        address indexed token,
        address indexed miner,
        uint256 amount,
        bytes32 provenanceHash,
        bytes32 minerInitHash
    );

    constructor(Config memory c) {
        if (
            c.factory.code.length == 0 || c.registry.code.length == 0 || c.deployer == address(0)
                || c.factory.codehash != c.factoryCodeHash || c.registry.codehash != c.registryCodeHash
                || c.originalSupply == 0 || c.originalSupply % 100 != 0 || c.minerIndex >= 8 || c.provenanceHash == 0
                || c.tokenInitHash == 0 || c.minerInitHash == 0 || c.tokenRuntimeHash == 0 || c.minerRuntimeHash == 0
                || c.minerConfigHash == 0
        ) revert InvalidPins();
        factory = IIMDProjectFactory(c.factory);
        registry = IIMDLaunchRegistry(c.registry);
        deployer = c.deployer;
        destinationChain = block.chainid;
        factoryCodeHash = c.factoryCodeHash;
        registryCodeHash = c.registryCodeHash;
        launchNumber = c.launchNumber;
        minerIndex = c.minerIndex;
        originalSupply = c.originalSupply;
        reserve = Math.mulDiv(c.originalSupply, 2, 5);
        provenanceHash = c.provenanceHash;
        tokenInitHash = c.tokenInitHash;
        minerInitHash = c.minerInitHash;
        tokenRuntimeHash = c.tokenRuntimeHash;
        minerRuntimeHash = c.minerRuntimeHash;
        minerConfigHash = c.minerConfigHash;
        _authority();
    }

    function _authority() private view {
        if (
            block.chainid != destinationChain || address(factory).codehash != factoryCodeHash
                || address(registry).codehash != registryCodeHash || factory.registry() != address(registry)
                || factory.deployer() != deployer
        ) revert WrongAuthority();
    }

    /// @dev recordedAt is a runtime fact, not part of the precommitted manifest identity.
    function recordHash(IIMDLaunchRegistry.Launch memory r) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                r.kind,
                r.launchNumber,
                r.sourceCommit,
                r.manifestHash,
                r.attestationHash,
                r.verifierKey,
                keccak256(bytes(r.sourceRepoUrl))
            )
        );
    }

    function configHash(FinancierMining m) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(m.fincr()),
                address(m.imd()),
                m.initialSupply(),
                m.initialQuote(),
                m.terminalFloor(),
                m.initializer(),
                m.operationsRecipient(),
                m.agentController()
            )
        );
    }

    /// @notice Permissionless trigger, no caller-selected destination or launch number.
    function forward(bytes calldata tokenCreationCode, bytes calldata minerCreationCode) external nonReentrant {
        if (forwarded) revert AlreadyForwarded();
        _authority();
        if (
            tokenCreationCode.length > 49152 || minerCreationCode.length > 49152
                || keccak256(tokenCreationCode) != tokenInitHash || keccak256(minerCreationCode) != minerInitHash
        ) revert WrongCreationCode();
        IIMDLaunchRegistry.Launch memory r = registry.launchOf(launchNumber);
        if (
            r.kind != bytes32("custom_token") || r.launchNumber != launchNumber || r.recordedAt == 0
                || r.recordedAt > block.timestamp || recordHash(r) != provenanceHash
        ) revert WrongLaunch();
        address token = factory.predictToken(launchNumber, tokenCreationCode);
        address target = factory.predictContract(launchNumber, minerIndex, minerCreationCode);
        if (
            token.code.length == 0 || target.code.length == 0 || token.codehash != tokenRuntimeHash
                || target.codehash != minerRuntimeHash
        ) revert WrongTarget();
        IIMDLaunchRegistry.Artifact[] memory artifacts = registry.artifactsOf(launchNumber);
        if (artifacts.length > 10) revert WrongArtifact();
        uint256 tokens;
        uint256 miners;
        for (uint256 i; i < artifacts.length; ++i) {
            IIMDLaunchRegistry.Artifact memory a = artifacts[i];
            if (a.role == bytes32("token")) {
                if (a.addr != token || a.name != bytes32("FINCR")) revert WrongArtifact();
                ++tokens;
            }
            if (a.role == bytes32("other") && a.name == bytes32("FinancierMiningWithAgents")) {
                if (a.addr != target) revert WrongArtifact();
                ++miners;
            }
        }
        if (tokens != 1 || miners != 1) revert WrongArtifact();
        FinancierMining m = FinancierMining(target);
        if (
            address(m.fincr()) != token || m.initializer() != address(this) || m.initialSupply() != originalSupply
                || m.miningReserve() != reserve || m.armed() || m.epoch() != 0 || configHash(m) != minerConfigHash
                || IInitialSupply(token).initialSupply() != originalSupply
        ) revert WrongTarget();
        IERC20 t = IERC20(token);
        uint256 held = t.balanceOf(address(this));
        uint256 beforeVault = t.balanceOf(target);
        if (held < reserve) revert MissingReserve();
        forwarded = true;
        t.safeTransfer(target, reserve);
        uint256 afterVault = t.balanceOf(target);
        uint256 remaining = t.balanceOf(address(this));
        if (
            remaining > held || held - remaining != reserve || afterVault < beforeVault
                || afterVault - beforeVault != reserve
        ) revert InexactForward();
        m.arm();
        if (!m.armed() || m.epoch() != 0) revert WrongTarget();
        emit ReserveForwarded(launchNumber, token, target, reserve, provenanceHash, minerInitHash);
    }
}
