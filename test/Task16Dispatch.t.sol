// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task16Base, Mining, Rounds, W, IntakeControl, IERC20} from "./helpers/Task16Base.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {IIMDIntake} from "../src/interfaces/IIMDIntake.sol";

/// Exact runtime with local storage; source identity/admission/acceptance are explicitly synthetic.
contract Task16DispatchTest is Task16Base {
    function testVaultSpendsActualWorkThenRecordedBindingEqualClaims() public {
        start();
        uint256 before = imd.balanceOf(address(miner));
        uint256 gasBefore = gasleft();
        bytes32 request = dispatch(0, 0);
        emit log_named_uint("Vault dispatch execution gas", gasBefore - gasleft());
        assertEq(before - imd.balanceOf(address(miner)), 0.5 ether);
        assertEq(imd.balanceOf(PAYEE), 0.5 ether);
        assertEq(miner.workBudget(), 0.35 ether);
        assertEq(miner.totalImdPaid(), 0.5 ether);
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        assertEq(miner.buybackBudget(), 0.075 ether);
        assertEq(miner.liquidityBudget(), 0.0375 ether);
        assertEq(miner.operationsBudget(), 0.0375 ether);
        (address payer, address target, bytes4 selector, bool completed) = intake.requests(request);
        assertEq(payer, address(miner));
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
        assertEq(intake.failureSelectorOf(request), bytes4(0));
        (uint256 round, bytes32 hash, uint256 at) = miner.workRequests(request);
        assertEq(round, 1);
        assertEq(hash, keccak256(body(0, 0)));
        assertEq(at, block.timestamp);
        vm.warp(block.timestamp + 5);
        Rounds.Admission memory a = admission(request, 0, 0);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
        vm.warp(rounds.context(0).end);
        settleEqual(a.jobId);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        assertSolvent();
    }

    function testDispatchRequiresAuthorityExactBodyAndOpenRound() public {
        scope(0);
        scope(1);
        bytes memory b = body(0, 0);
        vm.expectRevert(Rounds.NotStarted.selector);
        vm.prank(SETTLER);
        miner.dispatchWork(0, b);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        miner.dispatchWork(0, b);
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        vm.prank(SETTLER);
        miner.dispatchWork(0, bytes("UNRELATED"));
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        dispatch(1, 0);
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        dispatch(0, 1 + 10);
        vm.warp(rounds.context(0).end);
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        dispatch(0, 0);
        assertEq(miner.totalWorkSpent(), 0);
        assertSolvent();
    }

    function testDuplicateAndCrossRoundBodyReuseNeverRepurchase() public {
        scope(0);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(body(0, 0));
        vm.prank(SETTLER);
        rounds.precommitRound(1, hashes, keccak256("LOCAL future scope"));
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        dispatch(0, 0);
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        dispatch(0, 0);
        vm.warp(rounds.context(1).start);
        bytes memory b = body(0, 0);
        vm.expectRevert(Mining.InvalidWorkIntent.selector);
        vm.prank(SETTLER);
        miner.dispatchWork(1, b);
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        assertSolvent();
    }

    function testInsufficientBucketCannotSpendOtherLiabilitiesOrDonations() public {
        start(); // 0.35 work left, but vault holds 0.5 including other liabilities
        dispatch(0, 0);
        deal(IMD, address(900), 10 ether);
        vm.prank(address(900));
        imd.transfer(address(miner), 10 ether);
        uint256 held = imd.balanceOf(address(miner));
        vm.expectRevert(FinancierMining.Unfunded.selector);
        dispatch(0, 1);
        assertEq(miner.workBudget(), 0.35 ether);
        assertEq(imd.balanceOf(address(miner)), held);
        assertFalse(miner.dispatchedBody(keccak256(body(0, 1))));
        assertEq(held, miner.imdLiability() + 10 ether);
    }

    function testFeeDriftUpDownOrRetiredFailsExplicitlyAndRestoresIntent() public {
        start();
        uint256[3] memory prices = [uint256(0), uint256(0.4 ether), uint256(0.6 ether)];
        for (uint256 i; i < 3; ++i) {
            intake.setPrice("job.open@job-1", IMD, prices[i]);
            vm.expectRevert(abi.encodeWithSelector(Mining.WorkFeeChanged.selector, prices[i]));
            dispatch(0, 0);
            assertEq(miner.workBudget(), 0.85 ether);
            assertEq(intake.nonce(), 0);
            assertFalse(miner.dispatchedBody(keccak256(body(0, 0))));
            assertSolvent();
        }
        intake.setPrice("job.open@job-1", IMD, 0.5 ether);
        dispatch(0, 0);
        assertSolvent();
    }

    function testWrongChainAndRuntimeFailClosed() public {
        start();
        vm.chainId(1);
        vm.expectRevert(Mining.UnsupportedWorkService.selector);
        dispatch(0, 0);
        vm.chainId(4663);
        bytes memory original = INTAKE.code;
        vm.etch(INTAKE, hex"00");
        vm.expectRevert(Mining.UnsupportedWorkService.selector);
        dispatch(0, 0);
        vm.etch(INTAKE, original);
        original = IMD.code;
        vm.etch(IMD, hex"00");
        vm.expectRevert(Mining.UnsupportedWorkService.selector);
        dispatch(0, 0);
        vm.etch(IMD, original);
        assertSolvent();
    }

    function testConfiguredNoncanonicalAssetRefusesDispatch() public {
        MockToken otherAsset = new MockToken();
        Mining other = new Mining(
            address(token),
            address(otherAsset),
            1e27,
            1 ether,
            1 ether,
            address(this),
            address(105),
            SETTLER,
            keccak256("LOCAL wrong asset candidate"),
            1 days,
            1 days,
            1 hours
        );
        token.transfer(address(other), RESERVE);
        other.arm();
        Rounds r = other.agentRounds();
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(body(0, 0));
        vm.prank(SETTLER);
        r.precommitRound(0, hashes, keccak256("LOCAL FINANCIER scope"));
        otherAsset.mint(ALICE, 1 ether);
        vm.startPrank(ALICE);
        otherAsset.approve(address(other), 1 ether);
        other.bid(0, 1 ether, block.timestamp);
        vm.stopPrank();
        bytes memory b = body(0, 0);
        vm.expectRevert(Mining.UnsupportedWorkService.selector);
        vm.prank(SETTLER);
        other.dispatchWork(0, b);
        assertEq(other.workBudget(), 0.85 ether);
        assertEq(otherAsset.balanceOf(address(other)), 1 ether);
    }

    function testInsolventCustodyCannotSpendEvenWhenWorkAccountingLooksSufficient() public {
        start();
        deal(IMD, address(miner), 0.5 ether); // Synthetic confiscation; actual liabilities still 1 IMD.
        vm.expectRevert(FinancierMining.Unfunded.selector);
        dispatch(0, 0);
        assertEq(miner.workBudget(), 0.85 ether);
        assertEq(miner.totalWorkSpent(), 0);
        assertFalse(miner.dispatchedBody(keccak256(body(0, 0))));
    }

    function testRequestFailureRollsBackBudgetApprovalNonceAndIntent() public {
        start();
        bytes memory callData = abi.encodeCall(
            IIMDIntake.request,
            (bytes32("job.open@job-1"), body(0, 0), IIMDIntake.Callback(address(0), bytes4(0)), IMD, 0.5 ether)
        );
        vm.mockCallRevert(INTAKE, callData, abi.encodeWithSignature("Error(string)", "LOCAL service failure"));
        vm.expectRevert(bytes("LOCAL service failure"));
        dispatch(0, 0);
        assertEq(intake.nonce(), 0);
        assertEq(miner.workBudget(), 0.85 ether);
        assertFalse(miner.dispatchedBody(keccak256(body(0, 0))));
        assertEq(imd.balanceOf(PAYEE), 0);
        assertSolvent();
        vm.clearMockedCalls();
        dispatch(0, 0);
        assertSolvent();
    }

    function testInexactPaymentAndIncorrectRequestRecordRollbackEverything() public {
        start();
        vm.mockCall(
            IMD,
            abi.encodeWithSelector(IERC20.transferFrom.selector, address(miner), PAYEE, 0.5 ether),
            abi.encode(true)
        );
        vm.expectRevert(FinancierMining.InexactTransfer.selector);
        dispatch(0, 0);
        assertEq(intake.nonce(), 0);
        assertEq(miner.workBudget(), 0.85 ether);
        assertSolvent();
        vm.clearMockedCalls();
        bytes32 id = keccak256(abi.encode(block.chainid, INTAKE, uint256(1)));
        vm.mockCall(
            INTAKE, abi.encodeCall(intake.requests, (id)), abi.encode(address(999), address(0), bytes4(0), false)
        );
        vm.expectRevert(Mining.InvalidWorkRequest.selector);
        dispatch(0, 0);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(PAYEE), 0);
        assertSolvent();
        vm.clearMockedCalls();
        dispatch(0, 0);
        assertSolvent();
    }

    function testBindingMustMatchRealRecordedRequestRoundBodyAndTimestamp() public {
        start();
        bytes32 request = dispatch(0, 0);
        Rounds.Admission memory a = admission(request, 0, 0);
        a.requestId = keccak256("invented");
        reject(a, Rounds.UnrecordedDispatch.selector);
        a = admission(request, 0, 0);
        a.requestBodyHash = keccak256(body(0, 1));
        reject(a, Rounds.UnrecordedDispatch.selector);
        vm.warp(block.timestamp + 2);
        a = admission(request, 0, 0);
        a.requestedAt++;
        reject(a, Rounds.UnrecordedDispatch.selector);
        a = admission(request, 0, 0);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
        reject(a, Rounds.Duplicate.selector);
        assertSolvent();
    }

    function reject(Rounds.Admission memory a, bytes4 reason) internal {
        vm.expectRevert(reason);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
    }

    function testDelayedOrRefusedAdmissionNeverRefundsRepurchasesOrBlocksHuman() public {
        start();
        bytes32 request = dispatch(0, 0);
        vm.warp(rounds.context(0).end);
        Rounds.Admission memory a = admission(request, 0, 0);
        reject(a, Rounds.WrongTime.selector);
        vm.expectRevert(Rounds.UnrecordedDispatch.selector);
        vm.prank(SETTLER);
        rounds.bindJob(
            1,
            Rounds.Admission(request, a.jobId, keccak256(body(1, 0)), block.timestamp, block.timestamp, a.evidenceHash)
        );
        vm.prank(BOB);
        miner.bid(1, 1 ether, block.timestamp);
        vm.prank(ALICE);
        assertGt(miner.claimFincr(), 0);
        vm.prank(ALICE);
        assertEq(miner.claimImd(), 0);
        vm.warp(rounds.context(0).deadline + 1);
        rounds.expire(0);
        assertEq(rounds.totalAllocated(), 0);
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        assertSolvent();
    }

    function testReentrantIntakeCannotBidClaimOrDispatchAndOuterFailureRollsBack() public {
        start();
        IntakeReentryProbe probe = new IntakeReentryProbe();
        vm.mockFunction(INTAKE, address(probe), abi.encodeWithSelector(IIMDIntake.request.selector));
        vm.expectRevert(IntakeReentryProbe.ReentryBlocked.selector);
        dispatch(0, 0);
        assertEq(miner.workBudget(), 0.85 ether);
        assertEq(miner.epoch(), 1);
        assertFalse(miner.dispatchedBody(keccak256(body(0, 0))));
        assertSolvent();
    }

    function testFuzzWorkSpendNeverTouchesOtherBuckets(uint96 raw) public {
        start();
        uint256 amount = bound(uint256(raw), 1 ether, 1000 ether);
        vm.warp(block.timestamp + 1 hours);
        // Increase actual bid-funded work through the immutable first quote of a local candidate.
        // Repeated same-block bids also exercise immediate resets without extra FINCR issuance.
        uint256 quote = miner.currentPrice();
        while (quote <= amount && miner.workBudget() < 1.5 ether) {
            uint256 e = miner.epoch();
            vm.prank(BOB);
            miner.bid(e, quote, block.timestamp);
            quote = miner.currentPrice();
        }
        uint256 buyback = miner.buybackBudget();
        uint256 lp = miner.liquidityBudget();
        uint256 ops = miner.operationsBudget();
        uint256 outgoing = miner.totalOutgoingCredits();
        for (uint256 i; i < 3; ++i) {
            if (miner.workBudget() < 0.5 ether) break;
            dispatch(0, i);
            assertEq(miner.buybackBudget(), buyback);
            assertEq(miner.liquidityBudget(), lp);
            assertEq(miner.operationsBudget(), ops);
            assertEq(miner.totalOutgoingCredits(), outgoing);
            assertSolvent();
        }
    }

    function testPaidBindingRetainsProspectiveSubmissionCutoff() public {
        start();
        bytes32 request = dispatch(0, 0);
        vm.warp(block.timestamp + 5);
        Rounds.Admission memory a = admission(request, 0, 0);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
        // Actual settlement timing rejection remains covered by Task15Timing; a paid request grants no bypass.
        assertGt(rounds.jobBoundAt(a.jobId), a.requestedAt);
        vm.warp(rounds.context(0).end);
        settleEqual(a.jobId);
        assertSolvent();
    }
}

/// Test-only code redirection probes reentry while the production runtime pins remain intact.
contract IntakeReentryProbe {
    error ReentryBlocked();

    function request(bytes32, bytes calldata, IIMDIntake.Callback calldata, address, uint256)
        external
        returns (bytes32)
    {
        (bool ok, bytes memory reason) =
            msg.sender.call(abi.encodeWithSignature("dispatchWork(uint256,bytes)", 0, bytes("probe")));
        require(
            !ok && keccak256(reason) == keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()")),
            "dispatch not guarded"
        );
        (ok, reason) = msg.sender.call(abi.encodeWithSignature("bid(uint256,uint256,uint256)", 0, 0, block.timestamp));
        require(
            !ok && keccak256(reason) == keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()")),
            "bid not guarded"
        );
        (ok, reason) = msg.sender.call(abi.encodeWithSignature("claimFincr()"));
        require(
            !ok && keccak256(reason) == keccak256(abi.encodeWithSignature("ReentrancyGuardReentrantCall()")),
            "claim not guarded"
        );
        revert ReentryBlocked();
    }
}
