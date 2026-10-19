// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Task15Base, Rounds, W} from "./helpers/Task15Base.sol";

/// All positive mining evidence below is SYNTHETIC. No launch participant earns FINCR here.
contract Task27TrustBoundaryTest is Task15Base {
    function testRealCabalUUIDCannotQualifyAsUnboundFinancierWork() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        // Official bytes16 UUID, right-padded when represented as bytes32. It is real, but unrelated.
        a[0].jobId = bytes32(bytes16(hex"f4e36b375c2c40fa912dd99dd6180c35"));
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(Rounds.InvalidContribution.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, commitment);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testDishonestAuthorityCanOmitContributorDespiteValidCommitment() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory all, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory owners) = evidence(0, 2);
        W.Contribution[] memory subset = new W.Contribution[](1);
        Rounds.OwnerEvidence[] memory o = new Rounds.OwnerEvidence[](1);
        subset[0] = all[0];
        o[0] = owners[0];
        // A nonzero evidence hash is not an authenticated completeness oracle. This succeeds.
        finalize(0, subset, s, o);
        assertEq(rounds.claimable(0, all[0].beneficiary), miner.agentAllocation(0, 1 days));
        assertEq(rounds.claimable(0, all[1].beneficiary), 0);
        // This regression exposes the existing trust boundary; it does not certify settlement.
    }

    function testLateCompletionAfterTakeoverWithinSameRoundDoesNotAffectFinanciers() public {
        start();
        uint256 startTime = miner.genesis();
        vm.warp(startTime + 10);
        vm.prank(BOB);
        miner.bid(1, 10 ether, block.timestamp);
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 2);
        a[0].completedAt = startTime + 100;
        a[1].completedAt = startTime + 200;
        uint256 alice = miner.claimableFincr(ALICE);
        uint256 bob = miner.claimableFincr(BOB);
        finalize(0, a, s, o);
        uint256 share = miner.agentAllocation(0, 1 days) / 2;
        for (uint256 i; i < 2; ++i) {
            vm.prank(a[i].beneficiary);
            assertEq(rounds.claim(0), share);
        }
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), alice);
        vm.prank(BOB);
        assertEq(miner.claimFincr(), bob);
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid() + miner.totalFincrPaid(), RESERVE);
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
    }

    function testTwoProspectiveJobsUnionHasOneSharePerDistinctWallet() public {
        bytes32 secondBody = keccak256("SYNTHETIC second exact body");
        bytes32[] memory bodies = new bytes32[](2);
        bodies[0] = body(0);
        bodies[1] = secondBody;
        vm.prank(SETTLER);
        rounds.precommitRound(0, bodies, keccak256("SYNTHETIC two-job policy"));
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        bind(0);
        bytes32 request = keccak256("SYNTHETIC second request");
        bytes32 secondJob = keccak256("SYNTHETIC second job");
        mockDispatch(0, request, secondBody, block.timestamp);
        vm.prank(SETTLER);
        rounds.bindJob(
            0,
            Rounds.Admission(
                request, secondJob, secondBody, block.timestamp, block.timestamp, keccak256("SYNTHETIC admission")
            )
        );
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 2);
        a[1].jobId = secondJob;
        finalize(0, a, s, o);
        assertEq(rounds.claimable(0, a[0].beneficiary), rounds.claimable(0, a[1].beneficiary));
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
    }

    function testDuplicateIdentityCannotMultiplyShares() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 2);
        a[1].agentId = a[0].agentId;
        bytes32 commitment = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(Rounds.Duplicate.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, commitment);
        assertEq(rounds.totalAllocated(), 0);
    }
}
