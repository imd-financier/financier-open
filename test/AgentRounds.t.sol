// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IntegrationBase} from "./helpers/IntegrationBase.sol";
import {AgentRounds} from "../src/AgentRounds.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {FinancierMiningWithAgents} from "../src/FinancierMiningWithAgents.sol";
import {UnavailableWorkVerifier} from "../src/UnavailableWorkVerifier.sol";
import {IAgentWorkVerifier} from "../src/interfaces/IAgentWorkVerifier.sol";
import {FINCR} from "../src/FINCR.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {RoundVerifierMock} from "./helpers/RoundVerifierMock.sol";
import {LaunchTokenMock} from "./helpers/LaunchMocks.sol";

contract AgentRoundsTest is IntegrationBase {
    function setUp() public {
        deployIntegration(false);
        forwardAndStart();
    }

    function closeTime(uint256 id) internal {
        vm.warp(miner.genesis() + (id + 1) * 1 days);
    }

    function testGeneratedCompleteSetEqualRewardsAndNoDoubleClaim() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 3);
        bytes memory proof = approveRound(0, a);
        uint256 f = miner.claimableFincr(ALICE);
        rounds.finalize(0, a, proof);
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = budget / 3;
        assertEq(rounds.totalAllocated(), share * 3);
        assertEq(rounds.totalQuarantined(), budget % 3);
        for (uint256 i; i < 3; ++i) {
            vm.prank(a[i].beneficiary);
            assertEq(rounds.claim(0), share);
        }
        assertEq(miner.totalAgentPaid(), share * 3);
        assertEq(rounds.totalPaid(), share * 3);
        assertEq(miner.claimableFincr(ALICE), f);
        assertEq(token.balanceOf(address(miner)), RESERVE - share * 3);
        vm.expectRevert(AgentRounds.NoClaim.selector);
        vm.prank(AGENT);
        rounds.claim(0);
        vm.expectRevert(AgentRounds.AlreadyFinalized.selector);
        rounds.finalize(0, a, proof);
        assertEq(miner.requiredFincrCustody(), RESERVE - share * 3);
    }

    function testClaimBeforeFinalizationAndRecipientSubstitution() public {
        vm.expectRevert(AgentRounds.NoClaim.selector);
        vm.prank(AGENT);
        rounds.claim(0);
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        bytes memory proof = approveRound(0, a);
        a[0].beneficiary = BOB;
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, proof);
        a[0].beneficiary = AGENT;
        rounds.finalize(0, a, proof);
        vm.expectRevert(AgentRounds.NoClaim.selector);
        vm.prank(BOB);
        rounds.claim(0);
        // Frozen beneficiaries remain fixed after proof source revokes future validation.
        verifier.approve(abi.decode(proof, (bytes32)), 0);
        vm.prank(AGENT);
        rounds.claim(0);
        assertGt(token.balanceOf(AGENT), 0);
    }

    function testTamperedChainJobArtifactIdentityBeneficiaryReceiptAndDomain() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        bytes memory proof = approveRound(0, a);
        for (uint256 i; i < 8; ++i) {
            IAgentWorkVerifier.Contribution[] memory bad = contributions(0, 1);
            if (i == 0) bad[0].sourceChain = 4663;
            if (i == 1) bad[0].jobId = keccak256("unrelated job");
            if (i == 2) bad[0].artifactHash = keccak256("wrong artifact");
            if (i == 3) bad[0].identityRegistry = address(123);
            if (i == 4) bad[0].agentId = 999;
            if (i == 5) {
                bad[0].beneficiary = BOB;
                bad[0].controller = BOB;
            }
            if (i == 6) bad[0].receiptId = keccak256("other receipt");
            if (i == 7) bad[0].submissionHash = keccak256("other submission");
            vm.expectRevert(AgentRounds.UnverifiedWork.selector);
            rounds.finalize(0, bad, proof);
        }
        uint256 chain = block.chainid;
        vm.chainId(chain + 1);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, proof);
        vm.chainId(chain);
        IAgentWorkVerifier.Context memory c = rounds.context(0);
        c.vault = BOB;
        verifier.approve(abi.decode(proof, (bytes32)), rounds.commitment(c, a));
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, proof);
        assertEq(rounds.totalAllocated(), 0);
    }

    function testIncompleteAcceptedSetCannotExcludeOthersForLargerShare() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory full = contributions(0, 2);
        bytes memory proof = approveRound(0, full);
        IAgentWorkVerifier.Contribution[] memory subset = contributions(0, 1);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, subset, proof);
        rounds.finalize(0, full, proof);
        assertEq(rounds.claimable(0, AGENT), miner.agentAllocation(0, 1 days) / 2);
    }

    function testRejectedMissingRevokedAndChangedAuthorityFailClosed() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, abi.encode(bytes32(uint256(5))));
        bytes memory proof = approveRound(0, a);
        verifier.approve(abi.decode(proof, (bytes32)), 0);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, proof);
        verifier.approve(abi.decode(proof, (bytes32)), keccak256("authority changed"));
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, proof);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        uint256 price = miner.currentPrice();
        vm.prank(BOB);
        miner.bid(1, price, block.timestamp);
        assertEq(miner.iFinancier(), BOB);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testIdentityFreshnessExpiryAndCompletionWindow() public {
        closeTime(0);
        for (uint256 i; i < 6; ++i) {
            IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
            if (i == 0) a[0].identityObservedAt = block.timestamp - 1 hours - 1;
            if (i == 1) a[0].identityExpiresAt = block.timestamp - 1;
            if (i == 2) a[0].identityObservedAt = block.timestamp + 1;
            if (i == 3) a[0].completedAt = miner.genesis() - 1;
            if (i == 4) a[0].completedAt = block.timestamp;
            if (i == 5) a[0].identityExpiresAt = block.timestamp + 1 hours + 1;
            bytes memory proof = approveRound(0, a);
            vm.expectRevert(AgentRounds.InvalidContribution.selector);
            rounds.finalize(0, a, proof);
        }
    }

    function testAuthenticatedZeroAgentIdIsNotAnEmptySentinel() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        a[0].agentId = 0; // Some ERC-721 identity namespaces begin at zero; verifier authenticates existence.
        bytes memory proof = approveRound(0, a);
        rounds.finalize(0, a, proof);
        vm.prank(AGENT);
        assertEq(rounds.claim(0), miner.agentAllocation(0, 1 days));
    }

    function testDuplicateAgentOrControllerCannotMultiplyShare() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 2);
        a[1].agentId = a[0].agentId;
        bytes memory proof = approveRound(0, a);
        vm.expectRevert(AgentRounds.Duplicate.selector);
        rounds.finalize(0, a, proof);
        a = contributions(0, 2);
        a[1].controller = a[0].controller;
        a[1].beneficiary = a[0].beneficiary;
        proof = approveRound(0, a);
        vm.expectRevert(AgentRounds.Duplicate.selector);
        rounds.finalize(0, a, proof);
        assertEq(rounds.totalAllocated(), 0);
        assertFalse(rounds.usedReceipt(a[0].receiptId));
    }

    function testDuplicateReceiptsSubmissionsAndArtifactsRejected() public {
        closeTime(0);
        for (uint256 i; i < 3; ++i) {
            IAgentWorkVerifier.Contribution[] memory a = contributions(0, 2);
            if (i == 0) a[1].receiptId = a[0].receiptId;
            if (i == 1) a[1].submissionHash = a[0].submissionHash;
            if (i == 2) a[1].artifactHash = a[0].artifactHash;
            bytes memory proof = approveRound(0, a);
            vm.expectRevert(AgentRounds.Duplicate.selector);
            rounds.finalize(0, a, proof);
        }
    }

    function testJobAndEvidenceReplayAcrossRoundsRejected() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory first = contributions(0, 1);
        rounds.finalize(0, first, approveRound(0, first));
        closeTime(1);
        for (uint256 i; i < 4; ++i) {
            IAgentWorkVerifier.Contribution[] memory a = contributions(1, 1);
            if (i == 0) a[0].jobId = first[0].jobId;
            if (i == 1) a[0].receiptId = first[0].receiptId;
            if (i == 2) a[0].submissionHash = first[0].submissionHash;
            if (i == 3) a[0].artifactHash = first[0].artifactHash;
            bytes memory proof = approveRound(1, a);
            vm.expectRevert(AgentRounds.Duplicate.selector);
            rounds.finalize(1, a, proof);
        }
    }

    function testEmptyAndExpiredBudgetsRemainQuarantinedNotFutureJackpots() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory empty = contributions(0, 0);
        rounds.finalize(0, empty, approveRound(0, empty));
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        assertEq(rounds.totalAllocated(), 0);
        vm.warp(miner.genesis() + 3 days + 1);
        rounds.expire(1);
        uint256 q = rounds.totalQuarantined();
        assertEq(q, miner.agentAllocation(0, 2 days));
        IAgentWorkVerifier.Contribution[] memory a = contributions(2, 1);
        rounds.finalize(2, a, approveRound(2, a));
        vm.prank(AGENT);
        assertEq(rounds.claim(2), miner.agentAllocation(2 days, 3 days));
        assertEq(rounds.totalQuarantined(), q);
        vm.expectRevert(AgentRounds.NoClaim.selector);
        vm.prank(AGENT);
        rounds.claim(1);
    }

    function testLateOutOfOrderAndBeforeEndCannotTouchLaterRoundOrFinancier() public {
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        vm.expectRevert(AgentRounds.WrongTime.selector);
        rounds.finalize(0, a, "");
        closeTime(1);
        a = contributions(1, 1);
        rounds.finalize(1, a, approveRound(1, a));
        a = contributions(0, 1); // exactly deadline allowed
        rounds.finalize(0, a, approveRound(0, a));
        assertEq(rounds.totalFinalizedBudget(), miner.agentAllocation(0, 2 days));
        closeTime(4);
        a = contributions(2, 1);
        bytes memory lateProof = approveRound(2, a);
        vm.expectRevert(AgentRounds.WrongTime.selector);
        rounds.finalize(2, a, lateProof);
        rounds.expire(2);
        assertEq(miner.iFinancier(), ALICE);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
    }

    function testRoundAndProofBoundsAndNoArbitraryVaultExtraction() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 33);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, "");
        a = contributions(0, 1);
        bytes memory oversized = new bytes(16385);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, oversized);
        vm.expectRevert(AgentRounds.InvalidRound.selector);
        rounds.context(365);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        miner.payAgentReward(AGENT, 1);
        (bool ok,) = address(rounds).call(abi.encodeWithSignature("rescue(address,uint256)", address(token), RESERVE));
        assertFalse(ok);
    }

    function testBlockedAgentClaimRollbackAndFinancierIndependence() public {
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        rounds.finalize(0, a, approveRound(0, a));
        uint256 owed = rounds.claimable(0, AGENT);
        vm.mockCallRevert(
            address(token), abi.encodeWithSelector(token.transfer.selector, AGENT, owed), "agent recipient blocked"
        );
        vm.expectRevert();
        vm.prank(AGENT);
        rounds.claim(0);
        assertEq(rounds.claimable(0, AGENT), owed);
        assertEq(rounds.totalPaid(), 0);
        assertEq(miner.totalAgentPaid(), 0);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.clearMockedCalls();
        vm.prank(AGENT);
        rounds.claim(0);
    }

    function testVaultRejectsFutureAgentBudgetEvenFromBoundModule() public {
        vm.expectRevert(FinancierMining.Unfunded.selector);
        vm.prank(address(rounds));
        miner.payAgentReward(AGENT, 1);
        closeTime(0);
        uint256 scheduled = miner.agentReserved();
        vm.expectRevert(FinancierMining.Unfunded.selector);
        vm.prank(address(rounds));
        miner.payAgentReward(AGENT, scheduled + 1);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testLastRoundAndFinalFinancierNoSuccessor() public {
        closeTime(364);
        IAgentWorkVerifier.Contribution[] memory a = contributions(364, 1);
        rounds.finalize(364, a, approveRound(364, a));
        vm.prank(AGENT);
        rounds.claim(364);
        vm.warp(block.timestamp + 100 days);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), 320_000_000 ether);
        assertEq(miner.agentUnpaid() + miner.totalAgentPaid(), 80_000_000 ether);
        assertEq(token.balanceOf(address(miner)), miner.agentUnpaid());
    }

    function testFuzzZeroOneManyEqualSharesAndConservation(uint8 raw) public {
        uint256 n = uint256(raw) % 33;
        closeTime(0);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, n);
        rounds.finalize(0, a, approveRound(0, a));
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = n == 0 ? 0 : budget / n;
        for (uint256 i; i < n; ++i) {
            vm.prank(a[i].beneficiary);
            rounds.claim(0);
        }
        assertEq(rounds.totalPaid(), share * n);
        assertEq(rounds.totalQuarantined(), budget - share * n);
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid() + miner.totalFincrPaid(), RESERVE);
    }
}

contract AgentFailureIsolationTest is IntegrationBase {
    function testRealBoundaryIsDisabledAndUnknownProofCannotPay() public {
        vm.warp(1000000);
        token = new FINCR(SUPPLY);
        imd = new MockToken();
        UnavailableWorkVerifier disabled = new UnavailableWorkVerifier();
        miner = new FinancierMiningWithAgents(
            address(token),
            address(imd),
            SUPPLY,
            1 ether,
            0,
            address(this),
            OPS,
            address(disabled),
            POLICY,
            1 days,
            1 days,
            1 hours
        );
        rounds = miner.agentRounds();
        assertTrue(token.transfer(address(miner), RESERVE));
        miner.arm();
        imd.mint(ALICE, 1 ether);
        vm.startPrank(ALICE);
        imd.approve(address(miner), 1 ether);
        miner.bid(0, 1 ether, block.timestamp);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        vm.expectRevert(AgentRounds.UnverifiedWork.selector);
        rounds.finalize(0, a, hex"1234");
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.warp(block.timestamp + 1 days + 1);
        rounds.expire(0);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testClaimReentrancyBlocked() public {
        deployIntegration(true);
        forwardAndStart();
        vm.warp(block.timestamp + 1 days);
        IAgentWorkVerifier.Contribution[] memory a = contributions(0, 1);
        rounds.finalize(0, a, approveRound(0, a));
        LaunchTokenMock t = LaunchTokenMock(address(token));
        t.configure(false, address(rounds), abi.encodeCall(rounds.claim, (0)));
        vm.prank(AGENT);
        rounds.claim(0);
        assertTrue(t.attempted());
        assertFalse(t.reentered());
        assertEq(miner.totalAgentPaid(), miner.agentAllocation(0, 1 days));
    }
}
