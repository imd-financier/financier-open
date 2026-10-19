// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task15Base, Rounds, W, Mining} from "./helpers/Task15Base.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Task15AgentTest is Task15Base {
    function testWrongNamespaceWindowOrMissingSnapshotEvidenceRejects() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(a[0].beneficiary);
        rounds.claim(0);
        a[0].sourceChain = 4663;
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].sourceChain = 1;
        a[0].identityRegistry = address(999);
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].identityRegistry = rounds.IDENTITY_REGISTRY();
        uint256 completed = a[0].completedAt;
        a[0].completedAt = rounds.context(0).end;
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].completedAt = completed;
        bytes32 evidenceHash = s.acceptedSetEvidenceHash;
        s.acceptedSetEvidenceHash = 0;
        reject(a, s, o, Rounds.BadSnapshot.selector);
        s.acceptedSetEvidenceHash = evidenceHash;
        s.blockHash = 0;
        reject(a, s, o, Rounds.BadSnapshot.selector);
    }

    function testOwnerConsentCannotBeReusedForDifferentRound() public {
        start();
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        a[0].beneficiary = address(999);
        o[0].ownerAuthorizationHash = keccak256("MOCK domain-bound consent");
        finalize(0, a, s, o);
        vm.warp(rounds.context(1).start);
        bind(1);
        vm.warp(rounds.context(1).end);
        (a, s, o) = evidence(1, 1);
        a[0].beneficiary = address(999);
        o[0].ownerAuthorizationHash = keccak256("MOCK domain-bound consent");
        rejectRound(1, a, s, o, Rounds.Duplicate.selector);
    }

    function ready(uint256 n)
        internal
        returns (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o)
    {
        start();
        vm.warp(rounds.context(0).end);
        return evidence(0, n);
    }

    function reject(W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o, bytes4 err)
        internal
    {
        uint256 beforeAllocated = rounds.totalAllocated();
        bytes32 d = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(err);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, d);
        assertEq(rounds.totalAllocated(), beforeAllocated);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function rejectRound(
        uint256 id,
        W.Contribution[] memory a,
        Rounds.Snapshot memory s,
        Rounds.OwnerEvidence[] memory o,
        bytes4 err
    ) internal {
        bytes32 d = rounds.settlementCommitment(id, a, s, o);
        vm.expectRevert(err);
        vm.prank(SETTLER);
        rounds.finalize(id, a, s, o, d);
    }

    function testOneOwnerClaimsIndependentOfFinancierAndSuccessor() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        uint256 before = miner.claimableFincr(ALICE);
        finalize(0, a, s, o);
        assertEq(miner.claimableFincr(ALICE), before);
        uint256 share = rounds.claimable(0, a[0].beneficiary);
        assertGt(share, 0);
        vm.prank(a[0].beneficiary);
        rounds.claim(0);
        assertEq(token.balanceOf(a[0].beneficiary), share);
        assertEq(miner.totalAgentPaid(), share);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), before);
        vm.prank(ALICE);
        assertEq(miner.claimFincr(), 0);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(a[0].beneficiary);
        rounds.claim(0);
        vm.prank(BOB);
        miner.bid(1, 1 ether, block.timestamp);
        assertEq(miner.outgoingCredit(ALICE), 0);
        vm.prank(ALICE);
        assertEq(miner.claimImd(), 0);
    }

    function testMultipleOwnersEqualSharesAndDeterministicDust() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(3);
        finalize(0, a, s, o);
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = budget / 3;
        for (uint256 i; i < 3; i++) {
            assertEq(rounds.beneficiaries(0, i), a[i].beneficiary);
            vm.prank(a[i].beneficiary);
            assertEq(rounds.claim(0), share);
        }
        assertEq(rounds.totalPaid(), share * 3);
        assertEq(rounds.totalQuarantined(), budget % 3);
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), budget);
        assertGe(token.balanceOf(address(miner)), miner.requiredFincrCustody());
    }

    function testAuthorityOnlyAndNoReplayAcrossChainOrModule() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        bytes32 d = rounds.settlementCommitment(0, a, s, o);
        vm.expectRevert(Rounds.Unauthorized.selector);
        rounds.finalize(0, a, s, o, d);
        vm.chainId(1);
        vm.expectRevert(Rounds.BadCommitment.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, d);
        vm.chainId(4663);
        vm.expectRevert(Rounds.BadCommitment.selector);
        vm.prank(SETTLER);
        rounds.finalize(0, a, s, o, keccak256("OTHER MODULE"));
        finalize(0, a, s, o);
        rejectRound(0, a, s, o, Rounds.AlreadyFinalized.selector);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        vm.prank(SETTLER);
        miner.payAgentReward(SETTLER, 1);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        vm.prank(SETTLER);
        miner.claimOperations();
    }

    function testScopeMustExistAndBeCommittedBeforeEarning() public {
        bootstrap();
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        bytes32[] memory jobs = new bytes32[](1);
        jobs[0] = body(0);
        vm.expectRevert(Rounds.WrongTime.selector);
        vm.prank(SETTLER);
        rounds.precommitRound(0, jobs, keccak256("SPEC"));
        vm.warp(rounds.context(0).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        rejectRound(0, a, s, o, Rounds.ScopeUnavailable.selector);
        vm.warp(rounds.context(0).deadline + 1);
        rounds.expire(0);
        assertEq(rounds.totalAllocated(), 0);
    }

    function testScopePolicyAndJobCannotBeReplacedOrReused() public {
        scope(0);
        bytes32[] memory jobs = new bytes32[](1);
        jobs[0] = body(0);
        vm.expectRevert(Rounds.ScopeUnavailable.selector);
        vm.prank(SETTLER);
        rounds.precommitRound(0, jobs, keccak256("REPLACED POLICY"));
        bytes32[] memory duplicates = new bytes32[](2);
        duplicates[0] = body(1);
        duplicates[1] = body(1);
        vm.expectRevert(Rounds.Duplicate.selector);
        vm.prank(SETTLER);
        rounds.precommitRound(1, duplicates, keccak256("SPEC"));
        vm.expectRevert(Rounds.Unauthorized.selector);
        rounds.precommitRound(2, jobs, keccak256("SPEC"));
    }

    function testWrongUnrelatedJobOrRejectedMissingEvidenceFails() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        a[0].jobId = keccak256("UNRELATED");
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].jobId = job(0);
        a[0].submissionHash = 0;
        reject(a, s, o, Rounds.InvalidContribution.selector);
        // Public completion/UUID/NFT ownership cannot supply missing accepted submission.
    }

    function testDuplicateAgentOwnerPayoutAndNFTRejected() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(2);
        a[1].agentId = a[0].agentId;
        reject(a, s, o, Rounds.Duplicate.selector);
        a[1].agentId++;
        a[1].controller = a[0].controller;
        a[1].beneficiary = a[0].beneficiary;
        reject(a, s, o, Rounds.Duplicate.selector);
        a[1].controller = address(301);
        a[1].beneficiary = address(301);
        o[1].nftId = o[0].nftId;
        reject(a, s, o, Rounds.Duplicate.selector);
        o[1].nftId++;
        a[1].beneficiary = a[0].beneficiary;
        o[1].ownerAuthorizationHash = keccak256("MOCK REDIRECT");
        reject(a, s, o, Rounds.Duplicate.selector);
    }

    function testDuplicateReceiptsSubmissionsArtifactsRejected() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(2);
        bytes32 original = a[1].receiptId;
        a[1].receiptId = a[0].receiptId;
        reject(a, s, o, Rounds.Duplicate.selector);
        a[1].receiptId = original;
        original = a[1].submissionHash;
        a[1].submissionHash = a[0].submissionHash;
        reject(a, s, o, Rounds.Duplicate.selector);
        a[1].submissionHash = original;
        a[1].artifactHash = a[0].artifactHash;
        reject(a, s, o, Rounds.Duplicate.selector);
    }

    function testFreshSnapshotCutoffAndObservationBinding() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        uint256 t = s.timestamp;
        s.timestamp = rounds.context(0).end + 1;
        reject(a, s, o, Rounds.BadSnapshot.selector);
        s.timestamp = rounds.context(0).end - 1 hours - 1;
        reject(a, s, o, Rounds.BadSnapshot.selector);
        s.timestamp = t;
        a[0].identityObservedAt++;
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].identityObservedAt = t;
        a[0].identityExpiresAt--;
        reject(a, s, o, Rounds.InvalidContribution.selector);
    }

    function testRedirectNeedsOwnerAuthorizationAndFrozenAfterFinalization() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        address owner = a[0].controller;
        a[0].beneficiary = address(999);
        reject(a, s, o, Rounds.InvalidContribution.selector);
        o[0].ownerAuthorizationHash = keccak256("MOCK owner consent bound to chain/round/payout/cutoff");
        finalize(0, a, s, o);
        uint256 amount = rounds.claimable(0, address(999));
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(owner);
        rounds.claim(0);
        // A later sale cannot alter the frozen claim: no setter or ownership refresh exists.
        a[0].controller = address(888);
        a[0].beneficiary = address(888);
        rejectRound(0, a, s, o, Rounds.AlreadyFinalized.selector);
        vm.prank(address(999));
        assertEq(rounds.claim(0), amount);
    }

    function testEthereumOnlyContractOwnerCannotBePaidAtUndeployedAddress() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        o[0].sourceOwnerIsContract = true;
        o[0].payoutCompatibilityHash = keccak256("untrue compatibility");
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].beneficiary = address(999);
        o[0].ownerAuthorizationHash = keccak256("MOCK verified source contract consent");
        finalize(0, a, s, o);
        vm.prank(address(999));
        assertGt(rounds.claim(0), 0);
    }

    function testRobinhoodContractRecipientNeedsReviewedClaimPath() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        AgentClaimWallet wallet = new AgentClaimWallet();
        a[0].beneficiary = address(wallet);
        o[0].ownerAuthorizationHash = keccak256("MOCK consent");
        reject(a, s, o, Rounds.InvalidContribution.selector);
        o[0].payoutCompatibilityHash = keccak256("LOCAL reviewed AgentClaimWallet");
        finalize(0, a, s, o);
        wallet.claim(rounds, 0);
        uint256 received = token.balanceOf(address(wallet));
        assertGt(received, 0);
        wallet.send(IERC20(address(token)), address(999), received);
        assertEq(token.balanceOf(address(999)), received);
    }

    function testRegistryOrAdapterNeverTreatedAsOwnerWallet() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        a[0].controller = rounds.IMD_ADAPTER();
        a[0].beneficiary = a[0].controller;
        reject(a, s, o, Rounds.InvalidContribution.selector);
        a[0].controller = rounds.IDENTITY_REGISTRY();
        a[0].beneficiary = a[0].controller;
        reject(a, s, o, Rounds.InvalidContribution.selector);
    }

    function testClaimTransferFailurePreservesCreditAndFinancierCanClaim() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        finalize(0, a, s, o);
        uint256 credit = rounds.claimable(0, a[0].beneficiary);
        vm.mockCallRevert(
            address(token),
            abi.encodeCall(token.transfer, (a[0].beneficiary, credit)),
            abi.encodeWithSignature("Error(string)", "recipient failure")
        );
        vm.expectRevert(bytes("recipient failure"));
        vm.prank(a[0].beneficiary);
        rounds.claim(0);
        assertEq(rounds.claimable(0, a[0].beneficiary), credit);
        assertEq(rounds.totalPaid(), 0);
        assertEq(miner.totalAgentPaid(), 0);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.clearMockedCalls();
        vm.prank(a[0].beneficiary);
        assertEq(rounds.claim(0), credit);
    }

    function testEmptyExpiredAndOutageNeverRollOverOrGateFinancier() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(0);
        finalize(0, a, s, o);
        assertEq(rounds.totalAllocated(), 0);
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        vm.warp(rounds.context(1).deadline + 1);
        rounds.expire(1);
        assertEq(rounds.totalAllocated(), 0);
        vm.prank(BOB);
        miner.bid(1, 1 ether, block.timestamp);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.warp(miner.genesis() + 366 days);
        vm.prank(BOB);
        assertGt(miner.claimFincr(), 0);
        assertEq(miner.totalFincrPaid(), RESERVE * 4 / 5);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testEarlyLateOrOversizedFinalizationCannotPartiallyPay() public {
        start();
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(0, 1);
        rejectRound(0, a, s, o, Rounds.WrongTime.selector);
        vm.warp(rounds.context(0).end);
        (a, s, o) = evidence(0, 33);
        reject(a, s, o, Rounds.InvalidContribution.selector);
        (a, s, o) = evidence(0, 1);
        vm.warp(rounds.context(0).deadline + 1);
        rejectRound(0, a, s, o, Rounds.WrongTime.selector);
    }

    function testOutOfOrderFinalizationAndCrossRoundReceiptReuse() public {
        start();
        vm.warp(rounds.context(1).start);
        bind(1);
        vm.warp(rounds.context(1).end);
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = evidence(1, 1);
        finalize(1, a, s, o);
        bytes32 receipt = a[0].receiptId;
        (a, s, o) = evidence(0, 1);
        a[0].receiptId = receipt;
        reject(a, s, o, Rounds.Duplicate.selector);
    }

    function testExplicitTrustLimitDishonestAuthorityCanMisdirectOnlyAgentBudget() public {
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(1);
        a[0].controller = SETTLER; // syntactically valid but dishonest owner claim.
        a[0].beneficiary = SETTLER;
        uint256 financierBefore = miner.claimableFincr(ALICE);
        finalize(0, a, s, o);
        vm.prank(SETTLER);
        uint256 paid = rounds.claim(0);
        assertEq(paid, miner.agentAllocation(0, 1 days));
        assertEq(miner.claimableFincr(ALICE), financierBefore);
        assertLe(miner.totalAgentPaid(), RESERVE / 5); // The contract bounds loss; it DOES NOT prove truth.
    }

    function testFuzzEqualSplitWithinRoundCap(uint8 n) public {
        n = uint8(bound(n, 1, 32));
        (W.Contribution[] memory a, Rounds.Snapshot memory s, Rounds.OwnerEvidence[] memory o) = ready(n);
        finalize(0, a, s, o);
        uint256 budget = miner.agentAllocation(0, 1 days);
        uint256 share = budget / n;
        for (uint256 i; i < n; i++) {
            vm.prank(a[i].beneficiary);
            assertEq(rounds.claim(0), share);
        }
        assertEq(rounds.totalPaid() + rounds.totalQuarantined(), budget);
        assertEq(miner.totalAgentPaid(), share * n);
        assertGe(token.balanceOf(address(miner)), miner.requiredFincrCustody());
    }
}

contract AgentClaimWallet {
    address private immutable owner = msg.sender;

    function claim(Rounds r, uint256 id) external {
        require(msg.sender == owner, "wallet owner");
        r.claim(id);
    }

    function send(IERC20 t, address to, uint256 amount) external {
        require(msg.sender == owner, "wallet owner");
        require(t.transfer(to, amount), "wallet transfer");
    }
}
