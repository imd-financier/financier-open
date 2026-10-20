// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {PublisherGateway} from "../src/PublisherGateway.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FINCR} from "../src/FINCR.sol";
import {FounderFundedMining} from "../src/FounderFundedMining.sol";
import {RobinhoodJobController, INativeJobMining} from "../src/RobinhoodJobController.sol";
import {SeatOwnerAgentRounds} from "../src/SeatOwnerAgentRounds.sol";
import {FinancierMiningWithMarket} from "../src/FinancierMiningWithMarket.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {AttestedAgentRounds as Rounds} from "../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../src/interfaces/IAgentWorkVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISeatIntake {
    function setPrice(bytes32, address, uint256) external;
    function setPayTo(address) external;
    function setWriter(address) external;
    function setCallbackGas(uint64) external;
    function complete(bytes32, uint8, bytes32, string calldata, bytes calldata) external;
}

/// Actual pinned service runtimes, SYNTHETIC local state, identities, work and attester.
/// No production agent truth, signature, live job or Ethereum relay is fabricated.
contract Task30GatewayTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ALICE = address(101);
    address constant BOB = address(102);
    address constant OWNER = address(301);
    address constant OTHER = address(302);
    address constant ATTESTER = address(700);
    PublisherGateway gateway;
    address constant FOUNDER = 0xbcF19c0821A245383c127570615896Abac9e424F;
    FINCR token;
    FounderFundedMining miner;
    RobinhoodJobController controller;
    Rounds rounds;
    bytes32 request;
    bytes32 constant JOB = keccak256("SYNTHETIC FINANCIER job UUID");

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.etch(IMD, vm.parseBytes(vm.readLine("test/fixtures/task16/imd-runtime.hex")));
        vm.etch(INTAKE, vm.parseBytes(vm.readLine("test/fixtures/task16/intake-runtime.hex")));
        vm.etch(
            0x8366a39CC670B4001A1121B8F6A443A643e40951,
            vm.parseBytes(vm.readLine("test/fixtures/task23/manager-runtime.hex"))
        );
        vm.etch(
            0x19Bec7C2E1b2aadAf67b259744751a9960d66000,
            vm.parseBytes(vm.readLine("test/fixtures/task23/guard-runtime.hex"))
        );
        vm.store(IMD, 0, bytes32(uint256(uint160(address(this)))));
        (bool ok,) = IMD.call(abi.encodeWithSignature("enableTransfers()"));
        require(ok);
        vm.store(INTAKE, 0, bytes32(uint256(uint160(address(this)))));
        ISeatIntake(INTAKE).setPrice("job.open@job-1", IMD, 0.5 ether);
        ISeatIntake(INTAKE).setPayTo(address(800));
        ISeatIntake(INTAKE).setWriter(address(this));
        ISeatIntake(INTAKE).setCallbackGas(200_000);
        token = new FINCR(1e27);
        vm.prank(FOUNDER);
        gateway = new PublisherGateway(ATTESTER);
        vm.prank(FOUNDER);
        controller = new RobinhoodJobController(address(gateway));
        vm.prank(FOUNDER);
        gateway.bindController(controller, address(controller).codehash);
        vm.prank(FOUNDER);
        gateway.setPaused(false);
        FinancierMiningWithMarket.Config memory c = config();
        vm.prank(FOUNDER);
        miner = new FounderFundedMining(c);
        vm.prank(FOUNDER);
        controller.bindMiner(INativeJobMining(address(miner)));
        rounds = miner.agentRounds();
        deal(IMD, ALICE, 100 ether);
        deal(IMD, BOB, 100 ether);
        vm.prank(ALICE);
        IERC20(IMD).approve(address(miner), type(uint256).max);
        vm.prank(BOB);
        IERC20(IMD).approve(address(miner), type(uint256).max);
    }

    function config() internal view returns (FinancierMiningWithMarket.Config memory) {
        return FinancierMiningWithMarket.Config(
            address(token),
            IMD,
            1e27,
            10 ether,
            0.5 ether,
            FOUNDER,
            0x74421cdb9e6ad159358c4af7C59CFAE472A0541e,
            address(controller),
            controller.SPECIFICATION(),
            1 days,
            1 days,
            1 hours,
            0.1 ether
        );
    }

    function start() internal {
        token.transfer(address(miner), 4e26);
        vm.prank(FOUNDER);
        miner.arm();
        vm.prank(ALICE);
        miner.bid(0, 10 ether, block.timestamp);
        vm.prank(ALICE);
        request = controller.commission(0, 0);
        bind(request, JOB, 0);
        vm.warp(block.timestamp + 10);
    }

    function bind(bytes32 req, bytes32 job, uint256 category) internal {
        bytes32 bodyHash = keccak256(controller.body(0, category));
        vm.prank(ATTESTER);
        gateway.bindJob(
            0,
            Rounds.Admission(
                req, job, bodyHash, block.timestamp, block.timestamp, keccak256("SYNTHETIC backend admission")
            )
        );
    }

    function complete(bytes32 req, bool success) internal {
        bytes32 hash = keccak256("SYNTHETIC nonempty completed result");
        if (success) {
            ISeatIntake(INTAKE).complete(req, 0, hash, "uri", abi.encode(req, hash, "uri"));
        } else {
            ISeatIntake(INTAKE)
                .complete(req, 2, 0, "", abi.encode(req, uint8(2), bytes32("failed"), uint16(0), uint16(0), bytes("")));
        }
    }

    function evidence(uint256 n)
        internal
        view
        returns (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o)
    {
        W.Context memory c = rounds.context(0);
        s = Rounds.Snapshot(
            26_000_000,
            keccak256("SYNTHETIC finalized ETH header"),
            c.end - 15 minutes,
            keccak256("SYNTHETIC ownerOf/code observations"),
            keccak256("SYNTHETIC complete accepted work")
        );
        a = new W.Contribution[](n);
        o = new Rounds.OwnerEvidence[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 salt = bytes32(i + 1);
            a[i] = W.Contribution(
                1,
                rounds.IDENTITY_REGISTRY(),
                51_000 + i,
                OWNER,
                OWNER,
                JOB,
                keccak256(abi.encode("receipt", salt)),
                keccak256(abi.encode("submission", salt)),
                keccak256(abi.encode("nonempty artifact", salt)),
                rounds.jobBoundAt(JOB) + 2,
                s.timestamp,
                c.deadline
            );
            o[i] = Rounds.OwnerEvidence(100 + i, false, 0, 0, rounds.jobBoundAt(JOB) + 1);
        }
    }

    function lock(Rounds.Snapshot memory s) internal {
        vm.prank(ATTESTER);
        gateway.lockSnapshot(0, s);
    }

    function finalize(W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) internal {
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.prank(ATTESTER);
        gateway.finalizeRound(0, a, s, o, commitment);
    }

    function closeTime() internal {
        vm.warp(rounds.context(0).end);
    }

    function testEqualPerAgentAggregatesTwoSeatEntitlementsInOneWalletClaim() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(3);
        a[2].controller = OTHER;
        a[2].beneficiary = OTHER;
        closeTime();
        lock(s);
        finalize(a, s, o);
        (, uint256 budget, uint256 count, uint256 share,,) = rounds.rounds(0);
        assertEq(count, 3);
        assertEq(rounds.claimable(0, OWNER), 2 * share);
        assertEq(rounds.claimable(0, OTHER), share);
        assertEq(rounds.beneficiaries(0, 0), OWNER);
        assertEq(rounds.beneficiaries(0, 1), OTHER);
        assertEq(rounds.totalQuarantined(), budget - 3 * share);
        vm.prank(OWNER);
        assertEq(rounds.claim(0), 2 * share);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(OWNER);
        rounds.claim(0);
        vm.prank(OTHER);
        assertEq(rounds.claim(0), share);
        assertEq(miner.totalAgentPaid(), 3 * share);
        assertEq(token.balanceOf(OWNER), 2 * share);
    }

    // SYNTHETIC accepted work: distinct identities/receipts/submissions, identical report bytes.
    function sharedArtifactClaims(bool sameWallet) internal {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(2);
        string memory vector = vm.readFile("test/fixtures/task28/artifact-reuse.json");
        a[0].artifactHash = vm.parseJsonBytes32(vector, ".artifactHash");
        a[1].artifactHash = a[0].artifactHash;
        if (!sameWallet) {
            a[1].controller = OTHER;
            a[1].beneficiary = OTHER;
        }
        closeTime();
        lock(s);
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        // Like the resolver's eth_call: execute the real rounds validator from its controller,
        // then discard ALL simulated writes before the actual authorized settlement.
        uint256 state = vm.snapshotState();
        vm.prank(address(controller));
        rounds.finalize(0, a, s, o, commitment);
        assertTrue(vm.revertToState(state));
        vm.recordLogs();
        finalize(a, s, o);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSignature = keccak256("AgentAccepted(uint256,bytes32,address,bytes32,bytes32,bytes32,bytes32)");
        uint256 acceptedEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rounds) && logs[i].topics[0] == eventSignature) {
                (,,, bytes32 rawArtifact) = abi.decode(logs[i].data, (bytes32, bytes32, bytes32, bytes32));
                assertEq(rawArtifact, a[0].artifactHash);
                ++acceptedEvents;
            }
        }
        assertEq(acceptedEvents, 2);
        // Shared resolver/Solidity vectors pin the exact domain and canonical-identity encoding.
        assertTrue(rounds.usedArtifact(vm.parseJsonBytes32(vector, ".agent51000Key")));
        assertTrue(rounds.usedArtifact(vm.parseJsonBytes32(vector, ".agent51001Key")));
        assertFalse(rounds.usedArtifact(a[0].artifactHash));
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = budget / 2;
        vm.prank(OWNER);
        assertEq(rounds.claim(0), sameWallet ? 2 * share : share);
        if (!sameWallet) {
            vm.prank(OTHER);
            assertEq(rounds.claim(0), share);
        }
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(OWNER);
        rounds.claim(0);
        assertEq(miner.totalAgentPaid(), 2 * share);
        assertEq(rounds.totalQuarantined(), budget - 2 * share);
        vm.warp(miner.genesis() + 365 days);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), 3.2e26);
        (uint256 gross, uint256 financier, uint256 agents) = miner.cumulativeAt(365 days);
        assertEq(gross, 4e26);
        assertEq(financier, 3.2e26);
        assertEq(agents, 0.8e26);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
    }

    function testDistinctAgentsSameArtifactDifferentWalletsPreflightAndClaims() public {
        sharedArtifactClaims(false);
    }

    function testDistinctAgentsSameArtifactSameWalletPreflightAndClaims() public {
        sharedArtifactClaims(true);
    }

    function testGasModelThirtyTwoAgentsWithinExistingCap() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(32);
        closeTime();
        uint256 beforeGas = gasleft();
        lock(s);
        emit log_named_uint("gateway lockSnapshot warmed execution gas", beforeGas - gasleft());
        beforeGas = gasleft();
        finalize(a, s, o);
        emit log_named_uint("gateway finalizeRound 32 agents warmed execution gas", beforeGas - gasleft());
        assertEq(rounds.claimable(0, OWNER), (miner.agentAllocation(0, 1 days) / 32) * 32);
    }

    function testPauseRotationAndOldOperatorRevocation() public {
        start();
        complete(request, true);
        (, Rounds.Snapshot memory s,) = evidence(1);
        closeTime();
        vm.prank(FOUNDER);
        gateway.setPaused(true);
        vm.expectRevert(PublisherGateway.Unavailable.selector);
        lock(s);
        vm.prank(FOUNDER);
        gateway.replaceOperator(address(701));
        assertTrue(gateway.paused());
        vm.prank(FOUNDER);
        gateway.setPaused(false);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        lock(s);
        vm.prank(address(701));
        gateway.lockSnapshot(0, s);
        assertTrue(controller.snapshotDigest(0) != 0);
    }

    function testCannotRebindControllerEvenFounder() public {
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(FOUNDER);
        gateway.bindController(controller, address(controller).codehash);
    }

    function testWrongCallerChainSelectorAndNoCustodyPath() public {
        start();
        complete(request, true);
        (, Rounds.Snapshot memory s,) = evidence(1);
        closeTime();
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        gateway.lockSnapshot(0, s);
        vm.chainId(1);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        lock(s);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(FOUNDER);
        gateway.setPaused(false);
        vm.chainId(4663);
        vm.prank(ATTESTER);
        (bool ok,) = address(gateway).call(abi.encodeWithSignature("transfer(address,uint256)", ATTESTER, 4e26));
        assertFalse(ok);
        vm.prank(ATTESTER);
        (ok,) = address(gateway).call(abi.encodeWithSignature("commission(uint256,uint256)", 0, 1));
        assertFalse(ok);
        vm.prank(ATTESTER);
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        controller.lockSnapshot(0, s);
        assertEq(token.balanceOf(address(gateway)), 0);
    }

    function testControllerCodeChangeFailsClosed() public {
        start();
        (, Rounds.Snapshot memory s,) = evidence(1);
        vm.etch(address(controller), hex"00");
        vm.expectRevert(PublisherGateway.Unavailable.selector);
        lock(s);
    }

    function testBindingRejectsWrongPublisherFounderAndHash() public {
        vm.prank(FOUNDER);
        PublisherGateway fresh = new PublisherGateway(ATTESTER);
        vm.prank(FOUNDER);
        RobinhoodJobController wrongPublisher = new RobinhoodJobController(ATTESTER);
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(FOUNDER);
        fresh.bindController(wrongPublisher, address(wrongPublisher).codehash);
        RobinhoodJobController wrongFounder = new RobinhoodJobController(address(fresh));
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(FOUNDER);
        fresh.bindController(wrongFounder, address(wrongFounder).codehash);
        vm.prank(FOUNDER);
        RobinhoodJobController target = new RobinhoodJobController(address(fresh));
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(FOUNDER);
        fresh.bindController(target, bytes32(uint256(1)));
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        fresh.bindController(target, address(target).codehash);
        vm.prank(FOUNDER);
        fresh.bindController(target, address(target).codehash);
        assertTrue(fresh.paused());
    }

    function testSupersededFounderCannotDeployOrAdministerGateway() public {
        address oldFounder = 0xfB82A214fd2fe3F57F7ECd145cbc32cA38d03e19;
        assertEq(gateway.FOUNDER(), FOUNDER);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(oldFounder);
        new PublisherGateway(ATTESTER);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(oldFounder);
        gateway.setPaused(true);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(oldFounder);
        gateway.replaceOperator(address(701));
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(oldFounder);
        gateway.bindController(controller, address(controller).codehash);
    }

    function testOperatorMustBeSeparateEOAAndOnlyFounderCanDeployOrRotate() public {
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        new PublisherGateway(ATTESTER);
        address[4] memory bad = [address(0), FOUNDER, gateway.OPERATIONS(), address(token)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
            vm.prank(FOUNDER);
            gateway.replaceOperator(bad[i]);
        }
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        vm.prank(ATTESTER);
        gateway.replaceOperator(address(701));
    }

    function testEarlyAdmissionDuplicateAndConflictingAdmissionFail() public {
        start();
        assertEq(rounds.requestRoundPlusOne(request), 1);
        Rounds.Admission memory admission = Rounds.Admission(
            request,
            JOB,
            keccak256(controller.body(0, 0)),
            block.timestamp - 10,
            block.timestamp - 10,
            keccak256("duplicate")
        );
        vm.expectRevert(RobinhoodJobController.InvalidBinding.selector);
        vm.prank(ATTESTER);
        gateway.bindJob(0, admission);
        admission.jobId = keccak256("conflict");
        vm.expectRevert();
        vm.prank(ATTESTER);
        gateway.bindJob(0, admission);
    }

    function testPrebindingSubmissionAndGraceExpiryCannotBeRepaired() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        o[0].submittedAt = rounds.jobBoundAt(JOB);
        closeTime();
        lock(s);
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert();
        vm.prank(ATTESTER);
        gateway.finalizeRound(0, a, s, o, commitment);
        o[0].submittedAt = rounds.jobBoundAt(JOB) + 1;
        vm.warp(rounds.context(0).deadline + 1);
        commitment = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert();
        vm.prank(ATTESTER);
        gateway.finalizeRound(0, a, s, o, commitment);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
    }
}
