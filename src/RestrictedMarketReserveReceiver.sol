// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIMDProjectFactory, IIMDLaunchRegistry} from "./interfaces/IIMDLaunch.sol";
import {FinancierMiningWithMarket} from "./FinancierMiningWithMarket.sol";

interface IRegistryAuthority {
    function writer() external view returns (address);
}

/// @notice One-time authority selection of canonical FINCR, exact code-bound delivery and arm.
/// @dev Founder review is TRUSTED for canonical launch/source/allocation history. CREATE2
/// and reviewed self-contained init code bind executable targets, not the registry's assertions.
/// No number/source-attestation precommit; no owner transit, upgrade, rescue or arbitrary call.
contract RestrictedMarketReserveReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Pins {
        address factory;
        address registry;
        address deployer;
        bytes32 factoryHash;
        bytes32 registryHash;
        bytes32 tokenInitHash;
        bytes32 tokenRuntimeHash;
        bytes32 minerPrefixHash;
        uint256 minerPrefixLength;
    }

    struct Settings {
        address imd;
        uint256 supply;
        uint256 quote;
        uint256 floor;
        address operations;
        address settlementAuthority;
        bytes32 policy;
        uint256 roundSeconds;
        uint256 grace;
        uint256 maxAge;
        uint256 maxMarketBatch;
    }
    // Constructor-only storage; no setter, rescue, delegatecall or arbitrary executor.
    Pins private pins;
    Settings private settings;
    uint256 public immutable chain;
    bytes32 public immutable settingsHash;
    address public immutable bootstrapAuthority;
    bool public bootstrapped;
    uint64 public canonicalLaunchNumber;
    address public canonicalToken;
    address public canonicalMiner;
    bytes32 public bootstrapReviewHash;
    uint256 public immutable reserve;
    error Authority();
    error Creation();
    error Record();
    error Artifacts();
    error Target();
    error Funding();
    error Replay();
    error Delivery();
    event Bootstrapped(
        uint64 indexed launchNumber, address indexed token, address indexed miner, uint256 amount, bytes32 reviewHash
    );

    constructor(Pins memory p, Settings memory s, address bootstrapAuthority_) {
        require(block.chainid == 4663, "Robinhood only");
        require(p.factory.code.length != 0 && p.registry.code.length != 0 && p.deployer != address(0), "authority");
        require(p.tokenInitHash != 0 && p.tokenRuntimeHash != 0 && p.minerPrefixHash != 0, "code pins");
        require(p.minerPrefixLength > 0 && p.minerPrefixLength + 416 <= 49152, "init size");
        require(
            s.supply > 0 && s.supply % 100 == 0 && s.settlementAuthority != address(0)
                && s.settlementAuthority != address(this),
            "settings"
        );
        require(
            s.imd.code.length != 0 && s.operations != address(0) && s.operations != address(this) && s.quote > 0
                && s.quote >= s.floor && s.quote <= type(uint192).max && s.policy != 0 && s.roundSeconds >= 1 hours
                && s.roundSeconds <= 30 days && s.grace > 0 && s.grace <= 30 days && s.maxAge > 0 && s.maxAge <= 1 days,
            "settings"
        );
        require(bootstrapAuthority_ != address(0) && bootstrapAuthority_ != address(this), "bootstrap authority");
        require(s.maxMarketBatch >= 1e15 && s.maxMarketBatch <= 1 ether, "market settings");
        require(s.operations.code.length == 0, "Operations EOA");
        pins = p;
        settings = s;
        chain = block.chainid;
        settingsHash = keccak256(abi.encode(s));
        bootstrapAuthority = bootstrapAuthority_;
        reserve = s.supply / 100 * 40;
        _authority();
    }

    function _authority() private view {
        Pins memory p = pins;
        if (
            block.chainid != chain || p.factory.codehash != p.factoryHash || p.registry.codehash != p.registryHash
                || IIMDProjectFactory(p.factory).registry() != p.registry
                || IIMDProjectFactory(p.factory).deployer() != p.deployer
                || IRegistryAuthority(p.registry).writer() != p.factory
        ) revert Authority();
    }

    function minerArguments(address token) public view returns (bytes memory) {
        Settings memory s = settings;
        FinancierMiningWithMarket.Config memory c;
        c.fincr = token;
        c.imd = s.imd;
        c.supply = s.supply;
        c.quote = s.quote;
        c.floor = s.floor;
        c.initializer = address(this);
        c.operations = s.operations;
        c.authority = s.settlementAuthority;
        c.policy = s.policy;
        c.roundSeconds = s.roundSeconds;
        c.grace = s.grace;
        c.maxAge = s.maxAge;
        c.maxMarketBatch = s.maxMarketBatch;
        return abi.encode(c);
    }

    /// @dev Caller supplies evidence, never a destination. Maximum two EIP-3860 init blobs,
    /// <=10 registry artifacts, no iteration over previous launches/tokens/agents.
    function configuration() external view returns (Pins memory, Settings memory) {
        return (pins, settings);
    }

    /// @notice Only founder selection consumes the single authorization; all actions roll back
    /// together on failure. reviewHash commits the founder's canonical/source/allocation review.
    function bootstrap(uint64 number, bytes calldata tokenInit, bytes calldata minerInit, bytes32 reviewHash)
        external
        nonReentrant
    {
        if (msg.sender != bootstrapAuthority) revert Authority();
        if (bootstrapped) revert Replay();
        if (reviewHash == 0) revert Record();
        _authority();
        Pins memory p = pins;
        if (
            tokenInit.length > 49152 || keccak256(tokenInit) != p.tokenInitHash
                || minerInit.length != p.minerPrefixLength + 416
                || keccak256(minerInit[:p.minerPrefixLength]) != p.minerPrefixHash
        ) revert Creation();
        IIMDProjectFactory factory = IIMDProjectFactory(p.factory);
        address token = factory.predictToken(number, tokenInit);
        if (keccak256(minerInit[p.minerPrefixLength:]) != keccak256(minerArguments(token))) revert Creation();
        address target = factory.predictContract(number, 0, minerInit);
        _record(number, token, target);
        // Runtime identity follows exact reviewed init code executed by the pinned CREATE2
        // factory, not these getters. No proxies, external code generation or selfdestruct
        // are permitted in the reviewed constructors. Re-audit if either prefix changes.
        FinancierMiningWithMarket m = FinancierMiningWithMarket(target);
        if (
            token.codehash != p.tokenRuntimeHash || target.code.length == 0 || address(m.fincr()) != token
                || m.initialSupply() != settings.supply || m.initializer() != address(this)
                || m.miningReserve() != reserve || m.armed() || m.epoch() != 0 || m.genesis() != 0
                || m.agentController() != address(m.agentRounds())
                || address(m.market())
                    != address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", target, hex"02")))))
                || m.market().vault() != target || address(m.market().fincr()) != token
                || m.market().maxBatch() != settings.maxMarketBatch
                || address(m.agentRounds())
                    != address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", target, hex"01")))))
                || address(m.agentRounds().vault()) != target
                || m.agentRounds().settlementAuthority() != settings.settlementAuthority
                || m.agentRounds().policyHash() != settings.policy
                || m.agentRounds().roundSeconds() != settings.roundSeconds
                || m.agentRounds().graceSeconds() != settings.grace
                || m.agentRounds().identityMaxAge() != settings.maxAge
        ) revert Target();
        IERC20 t = IERC20(token);
        uint256 held = t.balanceOf(address(this));
        uint256 beforeVault = t.balanceOf(target);
        if (held < reserve) revert Funding();
        bootstrapped = true;
        canonicalLaunchNumber = number;
        canonicalToken = token;
        canonicalMiner = target;
        bootstrapReviewHash = reviewHash;
        t.safeTransfer(target, reserve);
        if (t.balanceOf(address(this)) != held - reserve || t.balanceOf(target) != beforeVault + reserve) {
            revert Delivery();
        }
        m.arm();
        if (!m.armed() || m.epoch() != 0 || m.genesis() != 0) revert Target();
        emit Bootstrapped(number, token, target, reserve, reviewHash);
        // Factory LP rounding/donations are deliberately stranded, not swept or rolled over.
    }

    function _record(uint64 number, address token, address target) private view {
        IIMDLaunchRegistry registry = IIMDLaunchRegistry(pins.registry);
        IIMDLaunchRegistry.Launch memory r = registry.launchOf(number);
        if (
            r.kind != bytes32("custom_token") || r.launchNumber != number || r.recordedAt == 0
                || r.recordedAt > block.timestamp
        ) revert Record();
        IIMDLaunchRegistry.Artifact[] memory a = registry.artifactsOf(number);
        if (a.length > 10) revert Artifacts();
        uint256 tokens;
        uint256 miners;
        for (uint256 i; i < a.length; ++i) {
            if (a[i].role == bytes32("token")) {
                if (a[i].name != bytes32("FINCR") || a[i].addr != token) revert Artifacts();
                ++tokens;
            } else if (a[i].addr == token) {
                revert Artifacts();
            }
            if (a[i].role == bytes32("other") && a[i].name == bytes32("FinancierMiningWithMarket")) {
                if (a[i].addr != target) revert Artifacts();
                ++miners;
            } else if (a[i].addr == target) {
                revert Artifacts();
            }
        }
        if (tokens != 1 || miners != 1) revert Artifacts();
    }
}
