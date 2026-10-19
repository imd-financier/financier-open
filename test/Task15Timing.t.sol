// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task15Base, Rounds, W} from "./helpers/Task15Base.sol";

/// Admission/body/timestamps/ownership are authority attestations generated ONLY for tests.
contract Task15TimingTest is Task15Base {
    function admission(uint256 id) internal view returns (Rounds.Admission memory) {
        return Rounds.Admission(
            keccak256(abi.encode("LOCAL REQUEST", id)),
            job(id),
            body(id),
            block.timestamp,
            block.timestamp,
            keccak256("MOCK Intake body/backend empty-submission admission")
        );
    }

    function rejectBinding(uint256 id, Rounds.Admission memory a, bytes4 err) internal {
        vm.expectRevert(err);
        vm.prank(SETTLER);
        rounds.bindJob(id, a);
    }

    function testFirstBidThenSimulatedAdmissionCanBeBoundAndSharedWithoutBudgetExpansion() public {
        scope(0);
        bootstrap();
        assertEq(rounds.jobRoundPlusOne(job(0)), 0);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.workBudget(), 0.85 ether); // funding, not production dispatch
        vm.warp(block.timestamp + 60);
        Rounds.Admission memory a = admission(0);
        a.requestId = keccak256("SIMULATED official request ID; no payment in this unit test");
        vm.warp(block.timestamp + 5);
        a.admittedAt = block.timestamp;
        a.jobId = bytes32(bytes16(keccak256(abi.encode("SIMULATED backend new UUID", a.requestId))));
        mockDispatch(0, a.requestId, a.requestBodyHash, a.requestedAt);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
        uint256 boundAt = rounds.jobBoundAt(a.jobId);
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory accepted, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 2);
        for (uint256 i; i < 2; ++i) {
            accepted[i].jobId = a.jobId;
            accepted[i].completedAt = boundAt + 2;
            o[i].submittedAt = boundAt + 1;
        }
        uint256 human = miner.claimableFincr(ALICE);
        finalize(0, accepted, s, o);
        uint256 budget = miner.agentAllocation(0, 1 days);
        for (uint256 i; i < 2; ++i) {
            vm.prank(accepted[i].beneficiary);
            assertEq(rounds.claim(0), budget / 2);
        }
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), human);
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), budget);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), RESERVE);
    }

    function testCannotBindBeforeGenesisBeforeWindowOrAtEnd() public {
        scope(0);
        Rounds.Admission memory a = admission(0);
        rejectBinding(0, a, Rounds.NotStarted.selector);
        bootstrap();
        scope(1);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        a = admission(1);
        rejectBinding(1, a, Rounds.WrongTime.selector);
        a = admission(0);
        vm.warp(rounds.context(0).end);
        rejectBinding(0, a, Rounds.WrongTime.selector);
    }

    function testAdmissionNeedsAuthorityCommittedBodyAndEvidence() public {
        scope(0);
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        Rounds.Admission memory a = admission(0);
        vm.expectRevert(Rounds.Unauthorized.selector);
        rounds.bindJob(0, a);
        a.requestBodyHash = keccak256("UNRELATED scope/body");
        rejectBinding(0, a, Rounds.InvalidContribution.selector);
        a = admission(0);
        a.evidenceHash = 0;
        rejectBinding(0, a, Rounds.InvalidContribution.selector);
        a = admission(0);
        a.requestId = 0;
        rejectBinding(0, a, Rounds.InvalidContribution.selector);
        a = admission(0);
        a.jobId = 0;
        rejectBinding(0, a, Rounds.InvalidContribution.selector);
        assertEq(rounds.jobBoundAt(job(0)), 0);
        assertEq(rounds.jobBindingsCommitment(0), 0);
    }

    function testRequestSubmissionAndAdmissionMustFollowRoundStartInOrder() public {
        scope(0);
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        vm.warp(block.timestamp + 10);
        Rounds.Admission memory a = admission(0);
        a.requestedAt = miner.genesis() - 1;
        rejectBinding(0, a, Rounds.WrongTime.selector);
        a = admission(0);
        a.admittedAt = a.requestedAt - 1;
        rejectBinding(0, a, Rounds.WrongTime.selector);
        a = admission(0);
        a.admittedAt = block.timestamp + 1;
        rejectBinding(0, a, Rounds.WrongTime.selector);
    }

    function testBodyRequestAndJobAreOneUseAcrossRoundsEvenIfNoPayout() public {
        start();
        Rounds.Admission memory a = admission(0);
        a.jobId = keccak256("SECOND JOB");
        a.requestId = keccak256("SECOND REQUEST");
        rejectBinding(0, a, Rounds.Duplicate.selector); // slot consumed, no retry/substitution
        vm.warp(rounds.context(1).start);
        a = admission(1);
        a.jobId = job(0);
        rejectBinding(1, a, Rounds.Duplicate.selector);
        a = admission(1);
        a.requestId = keccak256(abi.encode("LOCAL REQUEST", uint256(0)));
        rejectBinding(1, a, Rounds.Duplicate.selector);
        assertFalse(rounds.permittedJob(1, job(0)));
    }

    function testSubmissionBeforeOrAtBindingAndAcceptanceBeforeSubmissionReject() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        o[0].submittedAt = rounds.jobBoundAt(job(0));
        rejectSettlement(a, s, o);
        o[0].submittedAt--;
        rejectSettlement(a, s, o);
        o[0].submittedAt = rounds.jobBoundAt(job(0)) + 1;
        a[0].completedAt = o[0].submittedAt - 1;
        rejectSettlement(a, s, o);
        assertEq(rounds.totalAllocated(), 0);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function rejectSettlement(W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o)
        internal
    {
        bytes32 d = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(Rounds.InvalidContribution.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, d);
    }

    function testUnboundJobCannotBecomeEligibleAtFinalization() public {
        scope(0);
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        a[0].completedAt = miner.genesis() + 100;
        o[0].submittedAt = miner.genesis() + 99;
        rejectSettlement(a, s, o);
    }

    function testBoundaryCrossingJobNeverMigratesAndRewardsStayQuarantined() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        a[0].completedAt = rounds.context(0).end;
        rejectSettlement(a, s, o);
        Rounds.Admission memory retry = admission(1);
        retry.jobId = job(0);
        rejectBinding(1, retry, Rounds.Duplicate.selector);
        // Even an unbound old request cannot move into a future scope with truthful timestamps.
        retry = admission(1);
        retry.requestedAt = miner.genesis() + 10;
        rejectBinding(1, retry, Rounds.WrongTime.selector);
        vm.warp(rounds.context(0).deadline + 1);
        rounds.expire(0);
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        assertEq(rounds.totalAllocated(), 0);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
    }

    function testBindingCommitmentIncludedInSettlementDomainAndCannotReplaceScope() public {
        start();
        bytes32[] memory bodies = new bytes32[](1);
        bodies[0] = keccak256("REPLACEMENT");
        vm.expectRevert(Rounds.ScopeUnavailable.selector);
        vm.prank(SETTLER);
        rounds.precommitRound(0, bodies, keccak256("OTHER POLICY"));
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        (, bytes32 scopeHash) = rounds.scopes(0);
        bytes32 oldDigest = keccak256(abi.encode(rounds.context(0), scopeHash, a, s, o));
        vm.expectRevert(Rounds.BadCommitment.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, oldDigest);
        finalize(0, a, s, o);
        assertGt(rounds.totalAllocated(), 0);
    }

    function testFuzzBindingDelayNeverChangesFixedRoundAllocation(uint32 delay) public {
        delay = uint32(bound(delay, 1, 20 hours));
        scope(0);
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        vm.warp(miner.genesis() + delay);
        bind(0);
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        finalize(0, a, s, o);
        assertEq(rounds.totalAllocated(), miner.agentAllocation(0, 1 days));
    }
}
