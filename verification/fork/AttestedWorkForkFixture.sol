// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FinancierMiningWithSettlement as Mining} from "../../src/FinancierMiningWithSettlement.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {IIntakeViews} from "./RobinhoodIntake.t.sol";

/// SYNTHETIC backend, identities and complete accepted-set attestations; real local Intake payment.
abstract contract AttestedWorkForkFixture is Test {
    address constant TEST_SETTLER = address(702);

    function requestBody() internal pure returns (bytes memory) {
        return bytes(
            '{"objective":"LOCAL FORK ONLY: FINANCIER research, round 0, intent timing-regression. NEVER SUBMIT.","skill":"research-report","github":false}'
        );
    }

    function requestAndBind(Mining m) internal returns (bytes32 jobId) {
        vm.warp(m.genesis() + 60);
        uint256 requestedAt = block.timestamp;
        bytes32 requestId = purchaseFromVault(m);
        vm.warp(block.timestamp + 5);
        // Simulated backend assigns this UUID ONLY AFTER the actual local Intake request.
        jobId = bytes32(bytes16(keccak256(abi.encode("SIMULATED backend admission", requestId))));
        Rounds r = m.agentRounds();
        assertFalse(r.permittedJob(0, jobId));
        vm.prank(TEST_SETTLER);
        r.bindJob(
            0,
            Rounds.Admission(
                requestId,
                jobId,
                keccak256(requestBody()),
                requestedAt,
                block.timestamp,
                keccak256("MOCK backend mapping/empty submission evidence")
            )
        );
        assertTrue(r.permittedJob(0, jobId));
        vm.warp(block.timestamp + 2);
        emit log_string("Actual vault work bucket / Intake payment; backend UUID and ownership attestations simulated");
    }

    function purchaseFromVault(Mining m) internal returns (bytes32 requestId) {
        address intake = m.WORK_INTAKE();
        require(intake.codehash == m.INTAKE_CODEHASH(), "Intake drift");
        uint256 workBefore = m.workBudget();
        uint256 spentBefore = m.totalImdPaid();
        assertGe(workBefore, 0.5 ether);
        assertEq(IIntakeViews(intake).priceOf("job.open@job-1", address(m.imd())), 0.5 ether);
        uint256 vaultBefore = m.imd().balanceOf(address(m));
        uint256 payeeBefore = m.imd().balanceOf(IIntakeViews(intake).payTo());
        bytes memory b = requestBody();
        uint256 gasBefore = gasleft();
        vm.prank(TEST_SETTLER);
        requestId = m.dispatchWork(0, b);
        emit log_named_uint("Task16 actual vault dispatch execution gas", gasBefore - gasleft());
        assertEq(m.imd().balanceOf(IIntakeViews(intake).payTo()) - payeeBefore, 0.5 ether);
        assertEq(m.workBudget(), workBefore - 0.5 ether);
        assertEq(m.imd().balanceOf(address(m)), vaultBefore - 0.5 ether);
        assertEq(m.totalWorkSpent(), 0.5 ether);
        assertEq(m.totalImdPaid(), spentBefore + 0.5 ether);
        assertEq(m.imd().allowance(address(m), intake), 0);
        assertEq(m.imdLiability(), m.imd().balanceOf(address(m)));
        assertEq(m.totalBidVolume(), m.imdLiability() + m.totalImdPaid());
        assertRecordedRequest(m, requestId);
    }

    function assertRecordedRequest(Mining m, bytes32 id) internal view {
        (address payer, address target, bytes4 selector, bool completed) = IIntakeViews(m.WORK_INTAKE()).requests(id);
        assertEq(payer, address(m));
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
        (uint256 round, bytes32 hash, uint256 at) = m.workRequests(id);
        assertEq(round, 1);
        assertEq(hash, keccak256(requestBody()));
        assertEq(at, block.timestamp);
    }

    function settleAndClaim(Mining m, bytes32 admittedJob, uint256 count) internal {
        Rounds r = m.agentRounds();
        W.Context memory c = r.context(0);
        W.Contribution[] memory a = new W.Contribution[](count);
        Rounds.OwnerEvidence[] memory o = new Rounds.OwnerEvidence[](count);
        Rounds.Snapshot memory snap = Rounds.Snapshot(
            123456,
            keccak256("SYNTHETIC finalized source block"),
            c.end - 15 minutes,
            keccak256("MOCK ownership file"),
            keccak256("MOCK complete accepted set")
        );
        for (uint256 i; i < count; ++i) {
            address owner = address(uint160(300 + i));
            a[i] = W.Contribution(
                1,
                r.IDENTITY_REGISTRY(),
                52643 + i,
                owner,
                owner,
                admittedJob,
                keccak256(abi.encode("receipt", i)),
                keccak256(abi.encode("submission", i)),
                keccak256(abi.encode("artifact", i)),
                r.jobBoundAt(admittedJob) + 2,
                snap.timestamp,
                c.deadline
            );
            o[i] = Rounds.OwnerEvidence(472 + i, false, 0, 0, r.jobBoundAt(admittedJob) + 1);
        }
        bytes32 digest = r.settlementCommitment(0, a, snap, o);
        vm.prank(TEST_SETTLER);
        r.finalize(0, a, snap, o, digest);
        for (uint256 i; i < count; ++i) {
            vm.prank(a[i].beneficiary);
            uint256 paid = r.claim(0);
            assertEq(paid, m.agentAllocation(0, 1 days) / count);
        }
    }
}
