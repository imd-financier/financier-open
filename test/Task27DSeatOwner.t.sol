// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
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
contract Task27DSeatOwnerTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ALICE = address(101);
    address constant BOB = address(102);
    address constant OWNER = address(301);
    address constant OTHER = address(302);
    address constant ATTESTER = address(700);
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
        controller = new RobinhoodJobController(ATTESTER);
        miner = new FounderFundedMining(config());
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
            address(this),
            address(105),
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
        controller.bindJob(
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
        controller.lockSnapshot(0, s);
    }

    function finalize(W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) internal {
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.prank(ATTESTER);
        controller.finalizeRound(0, a, s, o, commitment);
    }

    function expectFinalize(
        W.Contribution[] memory a,
        Rounds.Snapshot memory s,
        Rounds.OwnerEvidence[] memory o,
        bytes4 error_
    ) internal {
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(error_);
        vm.prank(ATTESTER);
        controller.finalizeRound(0, a, s, o, commitment);
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

    function testUnrelatedRealCabalJobAndWrongNamespaceRejected() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        a[0].jobId = bytes32(bytes16(hex"f4e36b375c2c40fa912dd99dd6180c35"));
        expectFinalize(a, s, o, RobinhoodJobController.InvalidSettlement.selector);
        a[0].jobId = JOB;
        a[0].sourceChain = 4663;
        expectFinalize(a, s, o, Rounds.InvalidContribution.selector);
        a[0].sourceChain = 1;
        a[0].identityRegistry = rounds.NFT_COLLECTION();
        expectFinalize(a, s, o, Rounds.InvalidContribution.selector);
    }

    function testMissingRejectedOrFailedWorkCannotBeTurnedIntoAClaim() public {
        start();
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        expectFinalize(a, s, o, RobinhoodJobController.InvalidSettlement.selector);
        complete(request, false);
        expectFinalize(a, s, o, RobinhoodJobController.InvalidSettlement.selector);
        W.Contribution[] memory empty = new W.Contribution[](0);
        Rounds.OwnerEvidence[] memory noOwners = new Rounds.OwnerEvidence[](0);
        finalize(empty, s, noOwners);
        assertEq(rounds.totalAllocated(), 0);
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
    }

    function testZeroEvidenceAndRejectedSubmissionWithoutAcceptedReceiptReject() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        a[0].artifactHash = 0;
        expectFinalize(a, s, o, Rounds.InvalidContribution.selector);
        a[0].artifactHash = keccak256("artifact");
        a[0].receiptId = 0;
        expectFinalize(a, s, o, Rounds.InvalidContribution.selector);
    }

    function testNoDestinationSubstitutionAndContractOwnersQuarantineTheirShare() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory sn, Rounds.OwnerEvidence[] memory o) = evidence(3);
        a[1].controller = OTHER;
        a[1].beneficiary = OTHER;
        a[2].controller = address(303);
        a[2].beneficiary = address(303);
        closeTime();
        lock(sn);
        a[0].beneficiary = OTHER;
        o[0].ownerAuthorizationHash = keccak256("redirect");
        expectFinalize(a, sn, o, Rounds.InvalidContribution.selector);
        a[0].beneficiary = OWNER;
        o[0].ownerAuthorizationHash = 0;
        o[1].sourceOwnerIsContract = true;
        vm.etch(address(303), hex"00");
        finalize(a, sn, o);
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = budget / 3;
        assertEq(rounds.claimable(0, OWNER), share);
        assertEq(rounds.claimable(0, OTHER), 0);
        assertEq(rounds.claimable(0, address(303)), 0);
        assertEq(rounds.totalAllocated(), share);
        assertEq(rounds.totalQuarantined(), budget - share);
        vm.etch(OWNER, hex"00");
        vm.expectRevert(Rounds.InvalidContribution.selector);
        vm.prank(OWNER);
        rounds.claim(0);
        vm.etch(OWNER, "");
        vm.prank(OWNER);
        assertEq(rounds.claim(0), share);
    }

    function testFixedSnapshotTransferDoesNotRedirectTheFrozenOwnersClaim() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        Rounds.Snapshot memory altered = abi.decode(abi.encode(s), (Rounds.Snapshot));
        altered.blockHash = keccak256("later transferred NFT block");
        vm.expectRevert(RobinhoodJobController.InvalidSettlement.selector);
        lock(altered);
        expectFinalize(a, altered, o, RobinhoodJobController.InvalidSettlement.selector);
        // Changed later API/current NFT owner has no control over the immutable credited beneficiary.
        finalize(a, s, o);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(OTHER);
        rounds.claim(0);
        vm.prank(OWNER);
        assertGt(rounds.claim(0), 0);
    }

    function testMissingStaleFutureOwnershipProofAndWrongCommitmentReject() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        Rounds.Snapshot memory missing = abi.decode(abi.encode(s), (Rounds.Snapshot));
        missing.ownershipEvidenceHash = 0;
        vm.expectRevert(RobinhoodJobController.InvalidSettlement.selector);
        lock(missing);
        missing = abi.decode(abi.encode(s), (Rounds.Snapshot));
        missing.timestamp = rounds.context(0).end - 2 hours;
        vm.expectRevert(RobinhoodJobController.InvalidSettlement.selector);
        lock(missing);
        missing = abi.decode(abi.encode(s), (Rounds.Snapshot));
        missing.timestamp = rounds.context(0).end + 1;
        vm.expectRevert(RobinhoodJobController.InvalidSettlement.selector);
        lock(missing);
        lock(s);
        vm.expectRevert(Rounds.BadCommitment.selector);
        vm.prank(ATTESTER);
        controller.finalizeRound(0, a, s, o, bytes32(uint256(1)));
    }

    function testDuplicateAgentsSeatsAndSubmissionsCannotMultiplyShares() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(2);
        closeTime();
        lock(s);
        a[1].agentId = a[0].agentId;
        expectFinalize(a, s, o, Rounds.Duplicate.selector);
        a[1].agentId = 51_001;
        o[1].nftId = o[0].nftId;
        expectFinalize(a, s, o, Rounds.Duplicate.selector);
        o[1].nftId = 101;
        a[1].submissionHash = a[0].submissionHash;
        expectFinalize(a, s, o, Rounds.Duplicate.selector);
        a[1].submissionHash = keccak256(abi.encode("submission", bytes32(uint256(2))));
        a[1].receiptId = a[0].receiptId;
        expectFinalize(a, s, o, Rounds.Duplicate.selector);
    }

    /// Synthetic second official-shaped request: new UUID/receipt/submission bound to period1.
    function crossRoundReplay(uint256 replayKind) internal {
        start();
        controller.prepareRound(1); // prospective scope must precede period1.
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        finalize(a, s, o);
        // Agent settlement never gates the financier's independent accrual/claim.
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.prank(ALICE);
        bytes32 second = controller.commission(1, 0);
        bytes32 job2 = keccak256("SYNTHETIC period1 FINANCIER job");
        bytes32 bodyHash = keccak256(controller.body(1, 0));
        vm.prank(ATTESTER);
        controller.bindJob(
            1,
            Rounds.Admission(
                second, job2, bodyHash, block.timestamp, block.timestamp, keccak256("SYNTHETIC period1 admission")
            )
        );
        vm.warp(block.timestamp + 10);
        complete(second, true);
        W.Context memory c = rounds.context(1);
        s.timestamp = c.end - 15 minutes;
        s.blockNumber += 7200;
        s.blockHash = keccak256("SYNTHETIC period1 finalized ETH header");
        a[0].jobId = job2;
        a[0].completedAt = block.timestamp;
        a[0].identityObservedAt = s.timestamp;
        a[0].identityExpiresAt = c.deadline;
        o[0].submittedAt = block.timestamp - 1;
        if (replayKind != 2) a[0].submissionHash = keccak256("new period1 submission");
        if (replayKind != 3) a[0].receiptId = keccak256("new period1 receipt");
        if (replayKind != 0 && replayKind != 4) a[0].artifactHash = keccak256("genuinely NEW accepted report");
        if (replayKind == 4) {
            // A changed NFT owner cannot let the same agent recycle its consumed report.
            a[0].controller = OTHER;
            a[0].beneficiary = OTHER;
        }
        vm.warp(c.end);
        vm.prank(ATTESTER);
        controller.lockSnapshot(1, s);
        bytes32 commitment = rounds.settlementCommitment(1, a, s, o);
        if (replayKind != 1) vm.expectRevert(Rounds.Duplicate.selector);
        vm.prank(ATTESTER);
        controller.finalizeRound(1, a, s, o, commitment);
        if (replayKind == 1) {
            vm.prank(OWNER);
            assertEq(rounds.claim(1), miner.agentAllocation(1 days, 2 days));
        } else {
            assertEq(rounds.claimable(1, OWNER), 0);
        }
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
    }

    function testSameAgentSameArtifactAcrossPeriodsRejected() public {
        crossRoundReplay(0);
    }

    function testSameAgentNewAcceptedWorkAcrossPeriodsPermitted() public {
        crossRoundReplay(1);
    }

    function testSubmissionReplayAcrossPeriodsRejected() public {
        crossRoundReplay(2);
    }

    function testReceiptReplayAcrossPeriodsRejected() public {
        crossRoundReplay(3);
    }

    function testTransferredSeatCannotResetSameAgentArtifactReplayGuard() public {
        crossRoundReplay(4);
    }

    function testAutomationCannotSettleAndAttesterCannotCommissionOrWithdraw() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        vm.prank(ATTESTER);
        controller.commission(0, 1);
        closeTime();
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        controller.lockSnapshot(0, s);
        lock(s);
        bytes32 h = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        controller.finalizeRound(0, a, s, o, h);
        vm.expectRevert(Rounds.Unauthorized.selector);
        vm.prank(ATTESTER);
        rounds.finalize(0, a, s, o, h);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        vm.prank(ATTESTER);
        miner.payAgentReward(ATTESTER, 1);
        vm.prank(ATTESTER);
        (bool ok,) = address(controller).call(abi.encodeWithSignature("withdraw(address,uint256)", ATTESTER, 4e26));
        assertFalse(ok);
    }

    function testTrustedAttesterCanOmitOrInventMembersButCannotExceedAgentBudget() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        // Deliberately dishonest: omitted real second agent, invented ID/owner metadata.
        // There is NO on-chain Ethereum/acceptance proof. Passing is the disclosed trust boundary.
        a[0].agentId = 999_999;
        a[0].controller = ATTESTER;
        a[0].beneficiary = ATTESTER;
        o[0].nftId = 999_999;
        closeTime();
        lock(s);
        finalize(a, s, o);
        uint256 budget = miner.agentAllocation(0, 1 days);
        vm.prank(ATTESTER);
        assertEq(rounds.claim(0), budget);
        assertEq(miner.totalAgentPaid(), budget);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
        expectFinalize(a, s, o, Rounds.AlreadyFinalized.selector);
    }

    function testMultipleJobsRequireClosureAndTakeoverCannotMoveWorkOrBlockFinancier() public {
        start();
        vm.prank(ALICE);
        bytes32 second = controller.commission(0, 1);
        bytes32 job2 = keccak256("SYNTHETIC second FINANCIER job");
        bind(second, job2, 1);
        vm.warp(block.timestamp + 10);
        vm.prank(BOB);
        miner.bid(1, 10 ether, block.timestamp);
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(2);
        a[1].jobId = job2;
        o[1].submittedAt = rounds.jobBoundAt(job2) + 1;
        a[1].completedAt = o[1].submittedAt + 1;
        closeTime();
        lock(s);
        expectFinalize(a, s, o, RobinhoodJobController.InvalidSettlement.selector);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        complete(second, true);
        finalize(a, s, o);
        vm.prank(OWNER);
        assertEq(rounds.claim(0), (miner.agentAllocation(0, 1 days) / 2) * 2);
    }

    function testExpiredUnsettledRoundQuarantinesAndFinancierReceivesExactlyEightyPercent() public {
        start();
        vm.warp(miner.genesis() + 365 days);
        rounds.expire(0);
        (uint256 gross, uint256 financier, uint256 agents) = miner.cumulativeAt(365 days);
        assertEq(gross, 4e26);
        assertEq(financier, 3.2e26);
        assertEq(agents, 0.8e26);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), 3.2e26);
        assertEq(token.balanceOf(address(miner)), 0.8e26);
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testCommissionedButUnboundRequestCannotBeOmitted() public {
        start();
        vm.prank(ALICE);
        bytes32 second = controller.commission(0, 1);
        complete(request, true);
        complete(second, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1);
        closeTime();
        lock(s);
        expectFinalize(a, s, o, RobinhoodJobController.InvalidSettlement.selector);
        // Late admission cannot repair it retrospectively. Missing round expires to quarantine.
        vm.warp(rounds.context(0).deadline + 1);
        rounds.expire(0);
        assertEq(miner.totalAgentPaid(), 0);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
    }

    function testSameAgentAcrossTwoJobsCountsOnceAndOldDomainCannotReplay() public {
        start();
        vm.prank(ALICE);
        bytes32 second = controller.commission(0, 1);
        bytes32 job2 = keccak256("SYNTHETIC second FINANCIER job");
        bind(second, job2, 1);
        complete(request, true);
        complete(second, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(2);
        a[1].jobId = job2;
        a[1].agentId = a[0].agentId;
        o[1].submittedAt = rounds.jobBoundAt(job2) + 1;
        a[1].completedAt = o[1].submittedAt + 1;
        closeTime();
        lock(s);
        expectFinalize(a, s, o, Rounds.Duplicate.selector);
        // Complete evidence retains both work records; deterministic eligible union supplies one row.
        W.Contribution[] memory union = new W.Contribution[](1);
        union[0] = a[0];
        Rounds.OwnerEvidence[] memory owners = new Rounds.OwnerEvidence[](1);
        owners[0] = o[0];
        bytes32 digest = rounds.settlementCommitment(0, union, s, owners);
        vm.chainId(1);
        vm.expectRevert(Rounds.BadCommitment.selector);
        vm.prank(ATTESTER);
        controller.finalizeRound(0, union, s, owners, digest);
        vm.chainId(4663);
        finalize(union, s, owners);
        vm.prank(OWNER);
        assertEq(rounds.claim(0), miner.agentAllocation(0, 1 days));
    }

    function testFuzzFullReserveConservationWithAggregatedClaims(uint8 count_) public {
        uint256 count = bound(uint256(count_), 1, 32);
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(count);
        closeTime();
        lock(s);
        finalize(a, s, o);
        uint256 share = miner.agentAllocation(0, 1 days) / count;
        vm.prank(OWNER);
        assertEq(rounds.claim(0), share * count);
        vm.warp(miner.genesis() + 365 days);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), 3.2e26);
        assertEq(miner.totalAgentPaid(), share * count);
        assertEq(token.balanceOf(address(miner)), 0.8e26 - share * count);
        assertEq(token.balanceOf(address(miner)) + token.balanceOf(OWNER) + token.balanceOf(ALICE), 4e26);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFundingActivationAndCallbacksRetainOriginalGuards() public {
        vm.expectRevert();
        vm.prank(ALICE);
        miner.bid(0, 10 ether, block.timestamp);
        token.transfer(address(miner), 4e26 - 1);
        vm.expectRevert(FinancierMining.Unfunded.selector);
        miner.arm();
        token.transfer(address(miner), 2);
        miner.arm();
        assertEq(miner.genesis(), 0);
        vm.expectRevert(FinancierMining.AlreadyArmed.selector);
        miner.arm();
        vm.warp(block.timestamp + 1800);
        assertEq(miner.currentPrice(), 5.25 ether);
        vm.warp(block.timestamp + 1800);
        assertEq(miner.currentPrice(), 0.5 ether);
        vm.prank(ALICE);
        miner.bid(0, 0.5 ether, block.timestamp);
        uint256 g = miner.genesis();
        assertEq(miner.currentPrice(), 10 ether);
        vm.warp(block.timestamp + 1);
        vm.prank(BOB);
        miner.bid(1, 10 ether, block.timestamp);
        vm.prank(BOB);
        request = controller.commission(0, 0);
        bind(request, JOB, 0);
        bytes32 hash = keccak256("synthetic");
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector);
        miner.onResult(request, hash, "uri");
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector);
        vm.prank(INTAKE);
        miner.onResult(bytes32(uint256(99)), hash, "uri");
        complete(request, true);
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector);
        vm.prank(INTAKE);
        miner.onResult(request, hash, "uri");
        vm.warp(block.timestamp + 1);
        vm.prank(ALICE);
        miner.bid(2, 10 ether, block.timestamp);
        assertEq(miner.genesis(), g);
        assertEq(miner.currentPrice(), 10 ether);
    }

    function testRealCabalSeatRepresentationEightSharesSixWalletsSyntheticEligibleWork() public {
        // Genuine mapping at finalized Ethereum block 26227566; NOT a CABAL reward or real FINANCIER job.
        uint256[8] memory agents = [uint256(52707), 52608, 52206, 51506, 54231, 51873, 51879, 52266];
        uint256[8] memory seats = [uint256(717), 1182, 1269, 343, 102, 391, 970, 1166];
        address[8] memory holders = [
            address(uint160(uint256(319894527131999351284059704097056077528649309704))),
            address(uint160(uint256(712351832990570190973597843582833090538811882574))),
            address(uint160(uint256(923835586256536657382629897111297275557848885770))),
            address(uint160(uint256(1048496266483225306628623157579999666727006497023))),
            address(uint160(uint256(1048496266483225306628623157579999666727006497023))),
            address(uint160(uint256(1071353107501336015469973385449509153300552539112))),
            address(uint160(uint256(1071353107501336015469973385449509153300552539112))),
            address(uint160(uint256(1336727100340019670261317625171230615987172326244)))
        ];
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory sn, Rounds.OwnerEvidence[] memory o) = evidence(8);
        for (uint256 i; i < 8; ++i) {
            a[i].agentId = agents[i];
            a[i].controller = holders[i];
            a[i].beneficiary = holders[i];
            o[i].nftId = seats[i];
        }
        closeTime();
        lock(sn);
        finalize(a, sn, o);
        uint256 share = miner.agentAllocation(0, 1 days) / 8;
        assertEq(rounds.claimable(0, holders[3]), 2 * share);
        assertEq(rounds.claimable(0, holders[5]), 2 * share);
        assertEq(rounds.claimable(0, holders[0]), share);
        vm.prank(holders[3]);
        assertEq(rounds.claim(0), 2 * share);
    }

    function testTransferBeforeCutoffUsesNewOwnerWithoutPayoutRegistration() public {
        start();
        complete(request, true);
        (W.Contribution[] memory a, Rounds.Snapshot memory sn, Rounds.OwnerEvidence[] memory o) = evidence(1);
        // Synthetic pre-cutoff transfer attested at the fixed snapshot. No later redirect function exists.
        a[0].controller = OTHER;
        a[0].beneficiary = OTHER;
        closeTime();
        lock(sn);
        finalize(a, sn, o);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(OWNER);
        rounds.claim(0);
        vm.prank(OTHER);
        assertGt(rounds.claim(0), 0);
    }

    function testBindingIsFounderOnlyOneShotAndRequiredBeforeActivation() public {
        RobinhoodJobController fresh = new RobinhoodJobController(ATTESTER);
        FinancierMiningWithMarket.Config memory c = config();
        c.authority = address(fresh);
        c.policy = fresh.SPECIFICATION();
        FounderFundedMining candidate = new FounderFundedMining(c);
        token.transfer(address(candidate), 4e26);
        vm.expectRevert();
        candidate.arm();
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        vm.prank(ALICE);
        fresh.bindMiner(INativeJobMining(address(candidate)));
        fresh.bindMiner(INativeJobMining(address(candidate)));
        candidate.arm();
        vm.expectRevert(RobinhoodJobController.InvalidBinding.selector);
        fresh.bindMiner(INativeJobMining(address(candidate)));
        assertEq(candidate.currentPrice(), 10 ether);
        assertEq(candidate.genesis(), 0);
        assertLe(type(FounderFundedMining).creationCode.length + abi.encode(c).length, 49152);
    }
}
