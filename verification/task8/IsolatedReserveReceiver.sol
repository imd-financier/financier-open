// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIMDProjectFactory, IIMDLaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";
import {FinancierMiningWithAgents} from "../../src/FinancierMiningWithAgents.sol";

interface IRegistryAuthority {
    function writer() external view returns (address);
}

/// @notice LOCAL RESEARCH ONLY. Proves per-token custody, NOT canonical FINCR/source identity.
/// @dev No production replacement authorized. Trusts exact reviewed factory CREATE2 semantics
/// and exact, self-contained FINCR/miner creation code. NO provenance or launch-number pin.
/// A byte-identical second launch is intentionally independently eligible; never brand authentication.
contract IsolatedReserveReceiver is ReentrancyGuard {
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
        address verifier;
        bytes32 policy;
        uint256 roundSeconds;
        uint256 grace;
        uint256 maxAge;
    }
    // Constructor-only storage; no setter, rescue, delegatecall or arbitrary executor.
    Pins private pins;
    Settings private settings;
    uint256 public immutable chain;
    bytes32 public immutable settingsHash;
    bytes32 public immutable verifierHash;
    uint256 public immutable reserve;
    mapping(address token => bool) public forwarded;
    error Authority();
    error Creation();
    error Record();
    error Artifacts();
    error Target();
    error Funding();
    error Replay();
    error Delivery();
    event Forwarded(uint64 indexed launchNumber, address indexed token, address indexed miner, uint256 amount);

    constructor(Pins memory p, Settings memory s) {
        require(block.chainid == 4663, "Robinhood only");
        require(p.factory.code.length != 0 && p.registry.code.length != 0 && p.deployer != address(0), "authority");
        require(p.tokenInitHash != 0 && p.tokenRuntimeHash != 0 && p.minerPrefixHash != 0, "code pins");
        require(p.minerPrefixLength > 0 && p.minerPrefixLength + 384 <= 49152, "init size");
        require(s.supply > 0 && s.supply % 100 == 0 && s.verifier.code.length != 0, "settings");
        pins = p;
        settings = s;
        chain = block.chainid;
        settingsHash = keccak256(abi.encode(s));
        verifierHash = s.verifier.codehash;
        reserve = s.supply / 100 * 40;
        _authority();
    }

    function _authority() private view {
        Pins memory p = pins;
        if (
            block.chainid != chain || p.factory.codehash != p.factoryHash || p.registry.codehash != p.registryHash
                || IIMDProjectFactory(p.factory).registry() != p.registry
                || IIMDProjectFactory(p.factory).deployer() != p.deployer
                || IRegistryAuthority(p.registry).writer() != p.factory || settings.verifier.codehash != verifierHash
        ) revert Authority();
    }

    function minerArguments(address token) public view returns (bytes memory) {
        Settings memory s = settings;
        return abi.encode(
            token,
            s.imd,
            s.supply,
            s.quote,
            s.floor,
            address(this),
            s.operations,
            s.verifier,
            s.policy,
            s.roundSeconds,
            s.grace,
            s.maxAge
        );
    }

    /// @dev Caller supplies evidence, never a destination. Maximum two EIP-3860 init blobs,
    /// <=10 registry artifacts, no iteration over previous launches/tokens/agents.
    function forward(uint64 number, bytes calldata tokenInit, bytes calldata minerInit) external nonReentrant {
        _authority();
        Pins memory p = pins;
        if (
            tokenInit.length > 49152 || keccak256(tokenInit) != p.tokenInitHash
                || minerInit.length != p.minerPrefixLength + 384
                || keccak256(minerInit[:p.minerPrefixLength]) != p.minerPrefixHash
        ) revert Creation();
        IIMDProjectFactory factory = IIMDProjectFactory(p.factory);
        address token = factory.predictToken(number, tokenInit);
        if (forwarded[token]) revert Replay();
        if (keccak256(minerInit[p.minerPrefixLength:]) != keccak256(minerArguments(token))) revert Creation();
        address target = factory.predictContract(number, 0, minerInit);
        _record(number, token, target);
        // Runtime identity follows exact reviewed init code executed by the pinned CREATE2
        // factory, not these getters. No proxies, external code generation or selfdestruct
        // are permitted in the reviewed constructors. Re-audit if either prefix changes.
        FinancierMiningWithAgents m = FinancierMiningWithAgents(target);
        if (
            token.codehash != p.tokenRuntimeHash || target.code.length == 0 || address(m.fincr()) != token
                || m.initialSupply() != settings.supply || m.initializer() != address(this)
                || m.miningReserve() != reserve || m.armed() || m.epoch() != 0 || m.genesis() != 0
                || address(m.agentRounds())
                    != address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", target, hex"01")))))
        ) revert Target();
        IERC20 t = IERC20(token);
        uint256 held = t.balanceOf(address(this));
        uint256 beforeVault = t.balanceOf(target);
        if (held < reserve) revert Funding();
        forwarded[token] = true;
        t.safeTransfer(target, reserve);
        if (t.balanceOf(address(this)) != held - reserve || t.balanceOf(target) != beforeVault + reserve) {
            revert Delivery();
        }
        m.arm();
        if (!m.armed() || m.epoch() != 0 || m.genesis() != 0) revert Target();
        emit Forwarded(number, token, target, reserve);
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
            if (a[i].role == bytes32("other") && a[i].name == bytes32("FinancierMiningWithAgents")) {
                if (a[i].addr != target) revert Artifacts();
                ++miners;
            } else if (a[i].addr == target) {
                revert Artifacts();
            }
        }
        if (tokens != 1 || miners != 1) revert Artifacts();
    }
}
