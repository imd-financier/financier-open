// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../../src/FINCR.sol";
import {FinancierMiningWithSettlement as Mining} from "../../src/FinancierMiningWithSettlement.sol";
import {RestrictedReserveReceiver as Receiver} from "../../src/RestrictedReserveReceiver.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {IIMDLaunchRegistry as Registry} from "../../src/interfaces/IIMDLaunch.sol";
import {MockToken} from "./MockToken.sol";
import {LaunchRegistryMock, ProjectFactoryMock} from "./LaunchMocks.sol";

/// Synthetic authority/ownership and mutable registry MODEL, never official admission.
abstract contract Task15Base is Test {
    uint256 constant SUPPLY = 1e27;
    uint256 constant RESERVE = 4e26;
    address constant BOOTSTRAP = address(701);
    address constant SETTLER = address(702);
    address constant ALICE = address(101);
    address constant BOB = address(102);
    bytes32 constant POLICY = keccak256("LOCAL FINANCIER accepted-set policy; candidate only");
    bytes32 constant REVIEW = keccak256("LOCAL SYNTHETIC launch/source/allocation review");
    LaunchRegistryMock registry;
    ProjectFactoryMock factory;
    Receiver receiver;
    MockToken imd;
    FINCR token;
    Mining miner;
    Rounds rounds;
    bytes tokenInit;
    bytes minerInit;
    Receiver.Pins pins;
    Receiver.Settings settings;
    uint64 constant NUMBER = 15001;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_000_000);
        registry = new LaunchRegistryMock();
        factory = new ProjectFactoryMock(address(registry));
        vm.mockCall(address(registry), abi.encodeWithSignature("writer()"), abi.encode(address(factory)));
        imd = new MockToken();
        FINCR probe = new FINCR(SUPPLY);
        tokenInit = abi.encodePacked(type(FINCR).creationCode, abi.encode(SUPPLY));
        pins = Receiver.Pins(
            address(factory),
            address(registry),
            address(this),
            address(factory).codehash,
            address(registry).codehash,
            keccak256(tokenInit),
            address(probe).codehash,
            keccak256(type(Mining).creationCode),
            type(Mining).creationCode.length
        );
        settings = Receiver.Settings(
            address(imd), SUPPLY, 1 ether, 1 ether, address(105), SETTLER, POLICY, 1 days, 1 days, 1 hours
        );
        receiver = new Receiver(pins, settings, BOOTSTRAP);
        (token, miner) = launchModel(NUMBER);
        rounds = miner.agentRounds();
        minerInit = bytes.concat(type(Mining).creationCode, receiver.minerArguments(address(token)));
        imd.mint(ALICE, 100 ether);
        imd.mint(BOB, 100 ether);
        vm.prank(ALICE);
        imd.approve(address(miner), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(miner), type(uint256).max);
    }

    function launchModel(uint64 number) internal returns (FINCR t, Mining m) {
        address predicted = factory.predictToken(number, tokenInit);
        bytes memory code = bytes.concat(type(Mining).creationCode, receiver.minerArguments(predicted));
        Registry.Launch memory rec = Registry.Launch(
            "custom_token",
            number,
            uint64(block.timestamp),
            keccak256("source"),
            keccak256("manifest"),
            keccak256("attestation"),
            keccak256("verifier"),
            "https://example.invalid/local-model"
        );
        (address token_, address miner_) = factory.launch(tokenInit, code, rec, address(receiver));
        // Old mutable mock labels its app with the old class name; use the new exact artifact.
        Registry.Artifact[] memory a = new Registry.Artifact[](2);
        a[0] = Registry.Artifact("token", "FINCR", token_);
        a[1] = Registry.Artifact("other", "FinancierMiningWithSettlement", miner_);
        registry.setArtifacts(number, a);
        return (FINCR(token_), Mining(miner_));
    }

    function bootstrap() internal {
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, tokenInit, minerInit, REVIEW);
    }

    function job(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("LOCAL JOB", id));
    }

    function scope(uint256 id) internal {
        bytes32[] memory jobs = new bytes32[](1);
        jobs[0] = body(id);
        vm.prank(SETTLER);
        rounds.precommitRound(id, jobs, keccak256(abi.encode("FINANCIER SPEC", id)));
    }

    function body(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("LOCAL EXACT FINANCIER REQUEST BODY", id));
    }

    function bind(uint256 id) internal {
        // Round-isolation unit fixture only. Task16/fork tests execute real vault dispatch.
        mockDispatch(id, keccak256(abi.encode("LOCAL REQUEST", id)), body(id), block.timestamp);
        vm.prank(SETTLER);
        rounds.bindJob(
            id,
            Rounds.Admission(
                keccak256(abi.encode("LOCAL REQUEST", id)),
                job(id),
                body(id),
                block.timestamp,
                block.timestamp,
                keccak256("MOCK official Intake/backend admission")
            )
        );
    }

    function mockDispatch(uint256 id, bytes32 request, bytes32 hash, uint256 at) internal {
        vm.mockCall(address(miner), abi.encodeCall(miner.workRequests, (request)), abi.encode(id + 1, hash, at));
    }

    function start() internal {
        scope(0);
        scope(1);
        scope(2);
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        bind(0);
    }

    function evidence(uint256 id, uint256 count)
        internal
        view
        returns (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o)
    {
        W.Context memory c = rounds.context(id);
        s = Rounds.Snapshot(
            12345678 + id,
            keccak256(abi.encode("MOCK FINALIZED BLOCK", id)),
            c.end - 15 minutes,
            keccak256("MOCK OWNER SNAPSHOT"),
            keccak256("MOCK COMPLETE ACCEPTED SET")
        );
        a = new W.Contribution[](count);
        o = new Rounds.OwnerEvidence[](count);
        for (uint256 i; i < count; ++i) {
            bytes32 salt = keccak256(abi.encode(id, i));
            address owner = address(uint160(300 + i));
            a[i] = W.Contribution(
                1,
                rounds.IDENTITY_REGISTRY(),
                52643 + i,
                owner,
                owner,
                job(id),
                keccak256(abi.encode("receipt", salt)),
                keccak256(abi.encode("submission", salt)),
                keccak256(abi.encode("artifact", salt)),
                rounds.jobBoundAt(job(id)) + 2,
                s.timestamp,
                c.deadline
            );
            o[i] = Rounds.OwnerEvidence(472 + i, false, 0, 0, rounds.jobBoundAt(job(id)) + 1);
        }
    }

    function finalize(uint256 id, W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o)
        internal
    {
        bytes32 digest = rounds.settlementCommitment(id, a, s, o);
        vm.prank(SETTLER);
        rounds.finalize(id, a, s, o, digest);
    }
}
