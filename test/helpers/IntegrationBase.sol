// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../../src/FINCR.sol";
import {FinancierMiningWithAgents} from "../../src/FinancierMiningWithAgents.sol";
import {ReserveForwarder} from "../../src/ReserveForwarder.sol";
import {AgentRounds} from "../../src/AgentRounds.sol";
import {IIMDLaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";
import {IAgentWorkVerifier} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {MockToken} from "./MockToken.sol";
import {LaunchRegistryMock, ProjectFactoryMock, LaunchTokenMock} from "./LaunchMocks.sol";
import {RoundVerifierMock} from "./RoundVerifierMock.sol";

abstract contract IntegrationBase is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant RESERVE = 4e26;
    uint64 internal constant LAUNCH = 777;
    bytes32 internal constant POLICY =
        keccak256("LOCAL FINANCIER accepted-work policy fixture; NOT production approved");
    address internal constant OPS = address(105);
    address internal constant ALICE = address(101);
    address internal constant BOB = address(102);
    address internal constant AGENT = address(301);
    LaunchRegistryMock internal registry;
    ProjectFactoryMock internal factory;
    ReserveForwarder internal forwarder;
    FinancierMiningWithAgents internal miner;
    FINCR internal token;
    MockToken internal imd;
    RoundVerifierMock internal verifier;
    AgentRounds internal rounds;
    bytes internal tokenCode;
    bytes internal minerCode;
    IIMDLaunchRegistry.Launch internal record;

    function deployIntegration(bool maliciousToken) internal {
        vm.warp(1_000_000);
        registry = new LaunchRegistryMock();
        factory = new ProjectFactoryMock(address(registry));
        imd = new MockToken();
        verifier = new RoundVerifierMock();
        // CREATE address is independent of forwarder bytecode. Freeze nonce; no other CREATE until forwarder.
        address predictedForwarder = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        tokenCode = abi.encodePacked(
            maliciousToken ? type(LaunchTokenMock).creationCode : type(FINCR).creationCode, abi.encode(SUPPLY)
        );
        address predictedToken = factory.predictToken(LAUNCH, tokenCode);
        minerCode = abi.encodePacked(
            type(FinancierMiningWithAgents).creationCode,
            abi.encode(
                predictedToken,
                address(imd),
                SUPPLY,
                uint256(1 ether),
                uint256(1 ether),
                predictedForwarder,
                OPS,
                address(verifier),
                POLICY,
                uint256(1 days),
                uint256(1 days),
                uint256(1 hours)
            )
        );
        record = IIMDLaunchRegistry.Launch(
            "custom_token",
            LAUNCH,
            uint64(block.timestamp),
            keccak256("source"),
            keccak256("manifest"),
            keccak256("attestation"),
            keccak256("verifier-key"),
            "https://github.com/imd-financier/financier"
        );
        ReserveForwarder.Config memory c = ReserveForwarder.Config(
            address(factory),
            address(registry),
            address(this),
            address(factory).codehash,
            address(registry).codehash,
            LAUNCH,
            0,
            SUPPLY,
            keccak256(
                abi.encode(
                    record.kind,
                    record.launchNumber,
                    record.sourceCommit,
                    record.manifestHash,
                    record.attestationHash,
                    record.verifierKey,
                    keccak256(bytes(record.sourceRepoUrl))
                )
            ),
            keccak256(tokenCode),
            keccak256(minerCode),
            bytes32(uint256(1)),
            bytes32(uint256(1)),
            bytes32(uint256(1))
        );
        // Local dry run derives exact runtime hashes including immutable addresses. Not live factory evidence.
        uint256 snapshot = vm.snapshotState();
        ReserveForwarder probe = new ReserveForwarder(c);
        assertEq(address(probe), predictedForwarder);
        (address t, address m) = factory.launch(tokenCode, minerCode, record, address(probe));
        c.tokenRuntimeHash = t.codehash;
        c.minerRuntimeHash = m.codehash;
        c.minerConfigHash = probe.configHash(FinancierMiningWithAgents(m));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        forwarder = new ReserveForwarder(c);
        assertEq(address(forwarder), predictedForwarder);
        (t, m) = factory.launch(tokenCode, minerCode, record, address(forwarder));
        token = FINCR(t);
        miner = FinancierMiningWithAgents(m);
        rounds = miner.agentRounds();
        imd.mint(ALICE, 1e40);
        imd.mint(BOB, 1e40);
        vm.prank(ALICE);
        imd.approve(m, type(uint256).max);
        vm.prank(BOB);
        imd.approve(m, type(uint256).max);
    }

    function forwardAndStart() internal {
        forwarder.forward(tokenCode, minerCode);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
    }

    function contributions(uint256 roundId, uint256 count)
        internal
        view
        returns (IAgentWorkVerifier.Contribution[] memory a)
    {
        IAgentWorkVerifier.Context memory c = rounds.context(roundId);
        a = new IAgentWorkVerifier.Contribution[](count);
        for (uint256 i; i < count; ++i) {
            bytes32 salt = keccak256(abi.encode(roundId, i));
            address owner = address(uint160(301 + i));
            a[i] = IAgentWorkVerifier.Contribution(
                1,
                address(8004),
                i + 1,
                owner,
                owner,
                keccak256(abi.encode("job", roundId)),
                keccak256(abi.encode("receipt", salt)),
                keccak256(abi.encode("submission", salt)),
                keccak256(abi.encode("artifact", salt)),
                c.start + 1,
                block.timestamp,
                block.timestamp + 1 hours
            );
        }
    }

    function approveRound(uint256 id, IAgentWorkVerifier.Contribution[] memory a) internal returns (bytes memory) {
        bytes32 digest = rounds.commitment(rounds.context(id), a);
        bytes32 proofId = keccak256(abi.encode("LOCAL TEST ONLY", id, digest));
        verifier.approve(proofId, digest);
        return abi.encode(proofId);
    }
}
