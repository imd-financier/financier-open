// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {
    Task23Base,
    V4AttackActor,
    Mining,
    Market,
    IERC20,
    FINCR,
    IV4Market,
    IManagerInit
} from "./helpers/Task23Base.sol";
import {AttestedAgentRounds} from "../src/AttestedAgentRounds.sol";

contract Task23AttacksTest is Task23Base {
    function testWrongTokenUninitializedPoolAndInvalidSettingsFailClosed() public {
        FINCR other = new FINCR(1e27);
        Mining n = new Mining(config(address(other)));
        assertNotEq(n.market().poolId(), market.poolId());
        Market.Order memory o = Market.Order(0.001 ether, 1, 0, block.timestamp);
        Market nm = n.market();
        vm.expectRevert(Market.PriceBounds.selector);
        nm.validate(o, false);
        Mining.Config memory c = config(address(token));
        c.imd = address(other);
        vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
        new Mining(c);
        c = config(address(token));
        c.operations = address(token);
        vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
        new Mining(c);
        c = config(address(token));
        c.maxMarketBatch = 1 ether + 1;
        vm.expectRevert(Market.Unsupported.selector);
        new Mining(c);
        c.maxMarketBatch = 1e14;
        vm.expectRevert(Market.Unsupported.selector);
        new Mining(c);
    }

    function testPredictedMarketChildCannotMasqueradeAsOperationsEoa() public {
        Mining.Config memory c = config(address(token));
        address nextMiner = computeCreateAddress(address(this), vm.getNonce(address(this)));
        c.operations = computeCreateAddress(nextMiner, 2);
        assertEq(c.operations.code.length, 0);
        vm.expectRevert(bytes4(keccak256("InvalidConfiguration()")));
        new Mining(c);
    }

    function testBurnFailurePreservesBudgetButLpStillExecutes() public {
        uint256 supply = token.totalSupply();
        uint256 burned = miner.totalFincrBurned();
        uint256 positions = market.positions();
        vm.mockCall(address(token), abi.encodeWithSignature("burn(uint256)"), bytes(""));
        nextBid(BOB);
        assertEq(token.totalSupply(), supply);
        assertEq(miner.totalFincrBurned(), burned);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        assertEq(market.positions(), positions + 1);
        checkSolvent();
    }

    function testDishonestSettlementAndManagerReplacementKeepBidSafe() public {
        vm.mockCall(IMD, abi.encodeWithSelector(IERC20.transfer.selector, MANAGER), abi.encode(true));
        nextBid(BOB);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        vm.clearMockedCalls();
        vm.etch(MANAGER, hex"60006000f3");
        nextBid(ALICE);
        assertEq(miner.buybackBudget(), 0.015 ether);
        assertEq(miner.iFinancier(), ALICE);
        checkSolvent();
    }

    function testThinLiquidityPartialFillRevertsMarketNotBid() public {
        actor.modify(-int256(1e25 - 1e12), bytes32(0));
        uint160 price = market.spot();
        uint256 supply = token.totalSupply();
        nextBid(BOB);
        assertEq(market.spot(), price);
        assertEq(token.totalSupply(), supply);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        assertEq(miner.iFinancier(), BOB);
        checkSolvent();
    }

    function testDonationAndOtherOwnerCannotRecoverPrincipal() public {
        bytes32 salt = keccak256(abi.encode("FINANCIER permanent supplemental LP v1", uint256(0)));
        uint128 principal = market.positionLiquidity(salt);
        actor.donate(1 ether, 1 ether);
        vm.expectRevert();
        actor.modify(-int256(uint256(principal)), salt);
        nextBid(BOB);
        assertEq(market.positionLiquidity(salt), principal);
        assertEq(token.balanceOf(address(market)), market.strandedFincrDust());
        checkSolvent();
    }

    function testBothTokenOrdersUseExactCorrectSettlementSides() public {
        address low = address(0x1234);
        vm.etch(low, address(token).code);
        deal(low, address(this), 1e27, true);
        Mining n = new Mining(config(low));
        Market nm = n.market();
        assertFalse(nm.imdIs0());
        IERC20(low).transfer(address(n), 4e26);
        n.arm();
        IV4Market.PoolKey memory k = nm.key();
        vm.prank(FACTORY);
        IManagerInit(MANAGER).initialize(k, uint160(1 << 96));
        V4AttackActor a = new V4AttackActor(MANAGER, nm.key());
        IERC20(low).transfer(address(a), 1e26);
        deal(IMD, address(a), 1e26);
        a.modify(int256(1e25), 0);
        vm.startPrank(ALICE);
        IERC20(IMD).approve(address(n), 1 ether);
        n.bid{gas: 2_000_000}(0, 0.1 ether, block.timestamp);
        vm.stopPrank();
        assertGt(n.totalFincrBurned(), 0);
        assertEq(IERC20(low).totalSupply() + n.totalFincrBurned(), 1e27);
        assertGt(nm.totalLiquidity(), 0);
        assertEq(IERC20(IMD).balanceOf(address(n)), n.imdLiability());
    }

    function testSandwichPreBidPriceManipulationAndBackrun() public {
        uint256 snapshot = vm.snapshotState();
        uint256 burn0 = miner.totalFincrBurned();
        nextBid(BOB);
        uint256 baseline = miner.totalFincrBurned() - burn0;
        vm.revertToState(snapshot);
        uint256 actorImd = IERC20(IMD).balanceOf(address(actor));
        uint256 actorFincr = token.balanceOf(address(actor));
        actor.trade(market.imdIs0(), 1e24, market.imdIs0() ? uint160(1 << 95) : uint160(2 << 96));
        uint256 bought = token.balanceOf(address(actor)) - actorFincr;
        burn0 = miner.totalFincrBurned();
        nextBid(BOB);
        uint256 manipulated = miner.totalFincrBurned() - burn0;
        assertLt(manipulated, baseline); // accepted adverse pre-bid price, not independent protection
        actor.trade(!market.imdIs0(), bought, market.imdIs0() ? uint160(2 << 96) : uint160(1 << 95));
        uint256 finalImd = IERC20(IMD).balanceOf(address(actor));
        emit log_named_uint("Baseline victim FINCR burn", baseline);
        emit log_named_uint("Sandwiched victim FINCR burn", manipulated);
        // This large front-run loses fees in this synthetic deep pool; no universal profit claim.
        emit log_named_uint("Attacker IMD fee loss in this scenario", actorImd > finalImd ? actorImd - finalImd : 0);
        checkSolvent();
    }

    function testLpFailureAfterSwapRollsBackAllChanges() public {
        // First accumulate LP funds without changing existing position.
        vm.mockCallRevert(address(market), abi.encodeWithSelector(market.execute.selector), bytes("accumulate"));
        nextBid(BOB);
        vm.clearMockedCalls();
        uint160 price = market.spot();
        uint256 budget = miner.liquidityBudget();
        uint256 positions = market.positions();
        Market.Order memory o = market.makeOrder(budget, true);
        o.minLiquidity = type(uint128).max;
        // Isolated market frame with test-only vault impersonation; ordinary callers cannot enter.
        deal(IMD, address(market), budget);
        vm.prank(address(miner));
        vm.expectRevert(Market.Bounds.selector);
        market.execute(o, true);
        assertEq(market.spot(), price);
        assertEq(miner.liquidityBudget(), budget);
        assertEq(market.positions(), positions);
        checkSolvent();
    }

    function testOutgoingAndOperationsFallbacksStayDisjointFromMarket() public {
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, ALICE), bytes("reject outgoing"));
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, address(105)), bytes("reject ops"));
        nextBid(BOB);
        assertEq(miner.outgoingCredit(ALICE), 0.08 ether);
        assertEq(miner.operationsBudget(), 0.00375 ether);
        vm.clearMockedCalls();
        vm.prank(ALICE);
        assertEq(miner.claimImd(), 0.08 ether);
        vm.prank(address(105));
        assertEq(miner.claimOperations(), 0.00375 ether);
        checkSolvent();
    }

    function testWorkDispatchAndMarketSpendsRemainDisjoint() public {
        address intake = miner.WORK_INTAKE();
        vm.etch(intake, vm.parseBytes(vm.readLine("test/fixtures/task16/intake-runtime.hex")));
        vm.store(intake, bytes32(0), bytes32(uint256(uint160(address(this)))));
        (bool ok,) = intake.call(abi.encodeWithSignature("setPayTo(address)", address(800)));
        require(ok);
        (ok,) = intake.call(
            abi.encodeWithSignature("setPrice(bytes32,address,uint256)", bytes32("job.open@job-1"), IMD, 0.5 ether)
        );
        require(ok);
        bytes memory body = bytes("LOCAL EVM ONLY FINANCIER scoped work. NEVER SUBMIT.");
        bytes32[] memory bodies = new bytes32[](1);
        bodies[0] = keccak256(body);
        AttestedAgentRounds rounds = miner.agentRounds();
        vm.prank(SETTLER);
        rounds.precommitRound(1, bodies, keccak256("LOCAL policy"));
        // Sixty small bids fund 0.5 IMD work without using market or Operations budgets.
        for (uint256 i; i < 90; i++) {
            nextBid(i % 2 == 0 ? BOB : ALICE);
        }
        uint256 bb = miner.buybackBudget();
        uint256 lp = miner.liquidityBudget();
        uint256 at = miner.genesis() + 4 days;
        // Round 1 has elapsed after many hourly bids: use a prospectively scoped later round.
        at = miner.genesis() + 5 days;
        vm.prank(SETTLER);
        rounds.precommitRound(5, bodies, keccak256("LOCAL policy"));
        vm.warp(at);
        vm.prank(SETTLER);
        bytes32 id = miner.dispatchWork(5, body);
        assertNotEq(id, 0);
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        assertEq(miner.buybackBudget(), bb);
        assertEq(miner.liquidityBudget(), lp);
        assertEq(IERC20(IMD).allowance(address(miner), intake), 0);
        checkSolvent();
    }
}
