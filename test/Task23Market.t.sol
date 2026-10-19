// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task23Base, Mining, Market, IERC20, IV4Market} from "./helpers/Task23Base.sol";

contract Task23MarketTest is Task23Base {
    function testFirstBidAutomaticallyBurnsLocksAndPaysOperations() public view {
        assertEq(miner.MIN_MARKET_BATCH(), market.MIN_BATCH());
        assertGt(miner.totalFincrBurned(), 0);
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        assertEq(miner.totalBuybackSpent(), 0.0075 ether);
        assertGt(miner.totalLiquiditySpent(), 0.0037 ether);
        assertGt(market.totalLiquidity(), 0);
        assertEq(market.positions(), 1);
        assertEq(IERC20(IMD).balanceOf(address(105)), 0.00375 ether);
        assertEq(miner.operationsBudget(), 0);
        // Existing PROPOSED genesis rule, not silently approved: unowed 80% goes to work.
        assertEq(miner.workBudget(), 0.085 ether);
        assertEq(token.balanceOf(address(miner)), 4e26);
        checkSolvent();
    }

    function testTakeoverFullWaterfallAutomaticWithoutOperator() public {
        uint256 supply = token.totalSupply();
        uint256 burned = miner.totalFincrBurned();
        uint256 lp = miner.totalLiquiditySpent();
        uint256 outgoing = IERC20(IMD).balanceOf(ALICE);
        nextBid(BOB);
        assertEq(IERC20(IMD).balanceOf(ALICE) - outgoing, 0.08 ether);
        assertEq(miner.totalBuybackSpent(), 0.015 ether);
        assertEq(supply - token.totalSupply(), miner.totalFincrBurned() - burned);
        assertGt(miner.totalLiquiditySpent(), lp);
        assertEq(market.positions(), 2);
        assertEq(IERC20(IMD).balanceOf(address(105)), 0.0075 ether);
        assertEq(miner.workBudget(), 0.09 ether);
        assertEq(miner.outgoingCredit(ALICE), 0);
        assertEq(miner.operationsBudget(), 0);
        checkSolvent();
    }

    function testMarketFailureRestoresBudgetsAndDoesNotBlockTakeover() public {
        uint256 burned = miner.totalFincrBurned();
        uint256 positions = market.positions();
        uint256 spent = miner.totalBuybackSpent() + miner.totalLiquiditySpent();
        uint256 oldLp = miner.liquidityBudget();
        vm.mockCallRevert(address(market), abi.encodeWithSelector(market.execute.selector), bytes("reject market"));
        nextBid(BOB);
        assertEq(miner.iFinancier(), BOB);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        assertEq(miner.liquidityBudget(), oldLp + 0.00375 ether);
        assertEq(miner.totalFincrBurned(), burned);
        assertEq(market.positions(), positions);
        assertEq(miner.totalBuybackSpent() + miner.totalLiquiditySpent(), spent);
        checkSolvent();
    }

    function testOperationsFailureHasExactFallbackAndIndependentClaim() public {
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, address(105)), bytes("reject ops"));
        nextBid(BOB);
        assertEq(miner.operationsBudget(), 0.00375 ether);
        assertEq(miner.iFinancier(), BOB);
        assertGt(miner.totalFincrBurned(), 0);
        vm.clearMockedCalls();
        vm.prank(address(105));
        assertEq(miner.claimOperations(), 0.00375 ether);
        assertEq(miner.operationsBudget(), 0);
        checkSolvent();
    }

    function testOperationsInexactTransferRollsBackCreditAndLaterAutoRetry() public {
        uint256 received = IERC20(IMD).balanceOf(address(105));
        vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, address(105)), abi.encode(true));
        nextBid(BOB);
        assertEq(IERC20(IMD).balanceOf(address(105)), received);
        assertEq(miner.operationsBudget(), 0.00375 ether);
        vm.clearMockedCalls();
        nextBid(ALICE);
        assertEq(miner.operationsBudget(), 0);
        assertEq(IERC20(IMD).balanceOf(address(105)), received + 0.0075 ether);
        checkSolvent();
    }

    function testEntryPointsRequireSelfOrVaultAndHaveNoWithdrawalEscape() public {
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        miner.executeMarket(false);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        miner.payOperationsExact();
        Market.Order memory o = order(false);
        vm.expectRevert(Market.Unauthorized.selector);
        market.execute(o, false);
        string[6] memory names = [
            "withdraw(uint256)",
            "rescue(address,uint256)",
            "upgradeTo(address)",
            "collectFees()",
            "setOperator(address)",
            "migrate(address)"
        ];
        for (uint256 i; i < names.length; i++) {
            (bool ok,) = address(market).call(abi.encodeWithSignature(names[i], uint256(1)));
            assertFalse(ok);
        }
        checkSolvent();
    }

    function testWrongChainRuntimeAndUnsolicitedCallbacksRejected() public {
        vm.expectRevert(Market.Callback.selector);
        market.unlockCallback("unscoped");
        vm.prank(MANAGER);
        vm.expectRevert(Market.Callback.selector);
        market.unlockCallback("also unscoped");
        Market.Order memory o = order(false);
        vm.chainId(1);
        vm.expectRevert(Market.Unsupported.selector);
        market.validate(o, false);
        vm.chainId(4663);
        vm.etch(GUARD, hex"00");
        vm.expectRevert(Market.Unsupported.selector);
        market.validate(o, false);
    }

    function testDustDeadlineOutputAndLiquidityBounds() public {
        Market.Order memory o = order(false);
        o.amount = 0;
        vm.expectRevert(Market.Bounds.selector);
        market.validate(o, false);
        o = order(false);
        o.deadline = block.timestamp - 1;
        vm.expectRevert(Market.Bounds.selector);
        market.validate(o, false);
        o = order(false);
        o.minOut = 0;
        vm.expectRevert(Market.Bounds.selector);
        market.validate(o, false);
        o = order(true);
        o.minLiquidity = 0;
        vm.expectRevert(Market.Bounds.selector);
        market.validate(o, true);
        o = order(false);
        o.amount = market.maxBatch() + 1;
        vm.expectRevert(Market.Bounds.selector);
        market.validate(o, false);
    }

    function testEachBatchCappedAndOldPositionsNeverChange() public {
        bytes32 salt = keccak256(abi.encode("FINANCIER permanent supplemental LP v1", uint256(0)));
        uint128 principal = market.positionLiquidity(salt);
        nextBid(BOB);
        assertEq(market.positionLiquidity(salt), principal);
        assertEq(market.positions(), 2);
        assertEq(token.balanceOf(address(market)), market.strandedFincrDust());
        checkSolvent();
    }

    function testLowGasSkipsMarketWithoutBlockingBid() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 e = miner.epoch();
        uint256 p = miner.currentPrice();
        uint256 burned = miner.totalFincrBurned();
        vm.prank(BOB);
        miner.bid{gas: 450_000}(e, p, block.timestamp);
        assertEq(miner.iFinancier(), BOB);
        assertEq(miner.totalFincrBurned(), burned);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        checkSolvent();
    }

    function testGasGriefingChildIsCappedAndBidCompletes() public {
        // Infinite loop consumes the full child allowance; exact frame rollback restores budgets.
        vm.etch(address(market), hex"5b600056");
        nextBid(BOB);
        assertEq(miner.iFinancier(), BOB);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        assertEq(IERC20(IMD).balanceOf(address(105)), 0.0075 ether);
    }

    function testSmallBidThresholdsAccumulateWithoutLosingAllocation() public {
        Mining.Config memory c = config(address(token));
        c.quote = 0.01 ether;
        c.floor = 0.01 ether;
        Mining n = new Mining(c);
        token.transfer(address(n), 4e26);
        n.arm();
        vm.startPrank(ALICE);
        IERC20(IMD).approve(address(n), 1 ether);
        n.bid{gas: 2_000_000}(0, 0.01 ether, block.timestamp);
        vm.stopPrank();
        assertEq(n.totalFincrBurned(), 0);
        assertEq(n.buybackBudget(), 0.00075 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(ALICE);
        n.bid{gas: 2_000_000}(1, 0.01 ether, block.timestamp);
        assertGt(n.totalFincrBurned(), 0);
        assertEq(n.totalBuybackSpent(), 0.0015 ether);
        assertEq(n.market().positions(), 0);
        assertEq(n.liquidityBudget(), 0.00075 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(ALICE);
        n.bid{gas: 2_000_000}(2, 0.01 ether, block.timestamp);
        assertGt(n.market().totalLiquidity(), 0);
        assertEq(IERC20(IMD).balanceOf(address(n)), n.imdLiability());
    }

    function testConfiguredMaxBatchCapsBothBuckets() public {
        Mining.Config memory c = config(address(token));
        c.maxMarketBatch = 0.001 ether;
        Mining n = new Mining(c);
        token.transfer(address(n), 4e26);
        n.arm();
        vm.startPrank(ALICE);
        IERC20(IMD).approve(address(n), 1 ether);
        n.bid{gas: 2_000_000}(0, 0.1 ether, block.timestamp);
        vm.stopPrank();
        assertEq(n.totalBuybackSpent(), 0.001 ether);
        assertEq(n.buybackBudget(), 0.0065 ether);
        assertLe(n.totalLiquiditySpent(), 0.001 ether);
        assertGe(n.liquidityBudget(), 0.00275 ether);
        assertEq(IERC20(IMD).balanceOf(address(n)), n.imdLiability());
    }

    function testFuzzRepeatedTakeoversAndExecutionsConserve(uint8 count) public {
        count = uint8(bound(count, 1, 16));
        for (uint256 i; i < count; i++) {
            nextBid(i % 2 == 0 ? BOB : ALICE);
            checkSolvent();
            assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        }
    }
}
