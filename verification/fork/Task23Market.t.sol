// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MarketForkFixture} from "./MarketForkFixture.sol";
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {RestrictedMarketReserveReceiver as Receiver} from "../../src/RestrictedMarketReserveReceiver.sol";
import {FinancierMiningWithMarket as Mining} from "../../src/FinancierMiningWithMarket.sol";
import {PermanentV4Market as Market} from "../../src/market/PermanentV4Market.sol";
import {IV4Market} from "../../src/market/IV4Market.sol";
import {V4AttackActor} from "../../test/helpers/Task23Base.sol";
import {AttestedAgentRounds} from "../../src/AttestedAgentRounds.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Actual chain runtime AND fork storage. Factory deployer impersonation, token funding
/// are LOCAL TEST INPUTS. No production canonical FINCR or live pool depth is asserted.
contract Task23MarketForkTest is MarketForkFixture {
    /// Full local rehearsal with actual official runtime/storage. Authority is NOT
    /// production-approved: no accepted work is fabricated; its safe blocked state is tested.
    function testTask24LaunchToClaimsAndDeferredRetry() public {
        emit log_named_bytes("LOCAL token constructor arguments", abi.encode(uint256(1e27)));
        emit log_named_bytes("LOCAL miner constructor arguments", receiver.minerArguments(address(token)));
        (Receiver.Pins memory p, Receiver.Settings memory c) = receiver.configuration();
        emit log_named_bytes("LOCAL receiver constructor arguments", abi.encode(p, c, BOOTSTRAP));
        emit log_named_address("LOCAL token", address(token));
        emit log_named_address("LOCAL miner", address(miner));
        emit log_named_address("LOCAL receiver", address(receiver));
        emit log_named_bytes32("Actual factory runtime", address(FACTORY).codehash);
        emit log_named_bytes32("Actual manager runtime", market.MANAGER().codehash);
        emit log_named_bytes32("Actual guard runtime", market.GUARD().codehash);
        emit log_named_bytes32("Immutable-patched LOCAL miner runtime", address(miner).codehash);
        emit log_named_bytes32("Immutable-patched LOCAL receiver runtime", address(receiver).codehash);
        emit log_named_bytes32("Immutable-patched LOCAL rounds runtime", address(miner.agentRounds()).codehash);
        emit log_named_bytes32("Immutable-patched LOCAL market runtime", address(market).codehash);
        assertTrue(receiver.bootstrapped());
        assertTrue(miner.armed());
        assertEq(miner.workBudget(), 0.085 ether); // Founder-approved first bid: 85%.
        assertEq(token.balanceOf(address(miner)), 4e26);
        assertEq(address(miner.agentRounds()), vm.computeCreateAddress(address(miner), 1));
        assertEq(address(market), vm.computeCreateAddress(address(miner), 2));
        assertEq(miner.agentRounds().settlementAuthority(), address(702));
        uint256 start = miner.genesis();
        AttestedAgentRounds rounds = miner.agentRounds();
        // Production authority/evidence unavailable: no synthetic accepted proof is used.
        vm.prank(address(999));
        vm.expectRevert();
        rounds.precommitRound(1, new bytes32[](1), keccak256("unauthorized"));
        vm.prank(address(999));
        vm.expectRevert();
        rounds.claim(0);
        assertEq(miner.totalAgentPaid(), 0);

        // Exact outgoing and Operations transfer failures: fallback must be fully backed.
        vm.mockCallRevert(
            miner.WORK_ASSET(),
            abi.encodeWithSelector(IERC20.transfer.selector, address(101), 0.08 ether),
            "LOCAL injected outgoing failure"
        );
        vm.mockCallRevert(
            miner.WORK_ASSET(),
            abi.encodeWithSelector(IERC20.transfer.selector, OPS, 0.00375 ether),
            "LOCAL injected Operations failure"
        );
        uint256 supplyBefore = token.totalSupply();
        nextBid(2_000_000);
        assertEq(miner.epoch(), 2);
        assertEq(miner.outgoingCredit(address(101)), 0.08 ether);
        assertEq(miner.operationsBudget(), 0.00375 ether);
        assertEq(miner.workBudget(), 0.09 ether);
        assertLt(token.totalSupply(), supplyBefore);
        vm.clearMockedCalls();
        vm.prank(address(101));
        uint256 claimGas = gasleft();
        uint256 claimed = miner.claimFincr();
        emit log_named_uint("Former financier FINCR claim gas", claimGas - gasleft());
        (uint256 gross, uint256 financierEarned, uint256 agentEarned) = miner.cumulativeAt(block.timestamp - start);
        assertEq(claimed, financierEarned);
        assertEq(claimed + agentEarned, gross);
        assertEq(token.balanceOf(address(101)), claimed);
        vm.prank(address(101));
        assertEq(miner.claimImd(), 0.08 ether);
        vm.prank(OPS);
        assertEq(miner.claimOperations(), 0.00375 ether);
        assertEq(miner.outgoingCredit(address(101)), 0);
        assertEq(miner.operationsBudget(), 0);

        uint256 spentBefore = miner.totalBuybackSpent();
        nextBid(450_000); // LOCAL explicit low-gas transaction; optional work defers.
        assertEq(miner.epoch(), 3);
        assertEq(miner.totalBuybackSpent(), spentBefore);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        uint256 backlog = miner.buybackBudget();
        nextBid(2_000_000); // Later bid retries both accumulated market buckets.
        assertEq(miner.epoch(), 4);
        assertEq(miner.totalBuybackSpent() - spentBefore, backlog + 0.0075 ether);
        assertEq(miner.buybackBudget(), 0);
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        assertEq(token.balanceOf(address(miner)), miner.requiredFincrCustody());
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(miner)), miner.imdLiability());
        emit log_named_uint("Conserved mining reserve", 4e26);
        emit log_named_uint("Realized former financier FINCR", claimed);
        emit log_named_uint("Cumulative actual FINCR burn", miner.totalFincrBurned());
        emit log_named_uint("Permanent supplemental liquidity units", market.totalLiquidity());
        emit log_named_uint("Remaining deferred LP budget", miner.liquidityBudget());
        emit log_named_uint("Protected actual work budget", miner.workBudget());
        emit log_named_uint("Agent paid without accepted work (must be zero)", miner.totalAgentPaid());
    }

    function testTask23AutomaticBurnAndSeparatePermanentLpOnRealManager() public view {
        assertGt(miner.totalFincrBurned(), 0);
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        assertEq(miner.totalBuybackSpent(), 0.0075 ether);
        assertGt(market.totalLiquidity(), 0);
        assertEq(token.balanceOf(address(miner)), 4e26);
        assertEq(uint128(uint256(IV4Market(market.MANAGER()).extsload(initialPositionSlot))), initialPrincipal);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(OPS), 0.00375 ether);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(miner)), miner.imdLiability());
        assertEq(IERC20(miner.WORK_ASSET()).allowance(address(market), market.MANAGER()), 0);
        assertEq(token.allowance(address(market), market.MANAGER()), 0);
    }

    function testTask23FullBidWaterfallAndGasAtSmallBid() public {
        uint256 beforeOutgoing = IERC20(miner.WORK_ASSET()).balanceOf(address(101));
        nextBid(2_000_000);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(101)) - beforeOutgoing, 0.08 ether);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(OPS), 0.0075 ether);
        assertEq(miner.workBudget(), 0.09 ether);
        assertEq(miner.totalBuybackSpent(), 0.015 ether);
        assertEq(market.positions(), 2);
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(miner)), miner.imdLiability());
    }

    function testTask23LowGasPreservesMarketBudgetsAndDoesNotBlockBid() public {
        uint256 spent = miner.totalBuybackSpent();
        nextBid(450_000);
        assertEq(miner.iFinancier(), address(102));
        assertEq(miner.totalBuybackSpent(), spent);
        assertEq(miner.buybackBudget(), 0.0075 ether);
    }

    function testTask23SwapAndBurnFailureRollBackOnlyMarketFrame() public {
        uint256 supply = token.totalSupply();
        uint256 lp = market.positions();
        vm.mockCall(address(token), abi.encodeWithSignature("burn(uint256)"), bytes(""));
        nextBid(2_000_000);
        assertEq(token.totalSupply(), supply);
        assertEq(miner.buybackBudget(), 0.0075 ether);
        assertEq(market.positions(), lp + 1);
        assertEq(miner.iFinancier(), address(102));
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(miner)), miner.imdLiability());
    }

    function testTask23RecordedReferencePoolDepthIsNotLiveFincrDepth() public {
        (IProjectFactory.PoolKey memory k,,,) = FACTORY.positionOf(1727);
        bytes32 id = keccak256(abi.encode(k));
        bytes32 base = keccak256(abi.encode(id, uint256(6)));
        IV4Market manager = IV4Market(market.MANAGER());
        uint160 price = uint160(uint256(manager.extsload(base)));
        uint128 active = uint128(uint256(manager.extsload(bytes32(uint256(base) + 3))));
        emit log_named_address("Reference currency0, NOT production FINCR", k.currency0);
        emit log_named_address("Reference currency1, NOT production FINCR", k.currency1);
        emit log_named_uint("Observed reference pool sqrtPriceX96", price);
        emit log_named_uint("Observed reference active liquidity units", active);
        assertNotEq(id, market.poolId());
        emit log_named_uint("Rehearsal FINCR active liquidity before first bid", initialPrincipal);
        emit log_named_uint(
            "Rehearsal approximate virtual IMD reserve at initial spot",
            Math.mulDiv(initialPrincipal, uint256(1) << 96, beforeFirstBid)
        );
    }

    function testTask23ActualRuntimeFrontRunBidAndBackrun() public {
        uint256 snap = vm.snapshotState();
        uint256 burn0 = miner.totalFincrBurned();
        nextBid(2_000_000);
        uint256 baseline = miner.totalFincrBurned() - burn0;
        vm.revertToState(snap);
        V4AttackActor attacker = new V4AttackActor(market.MANAGER(), market.key());
        deal(miner.WORK_ASSET(), address(attacker), 1 ether);
        attacker.trade(market.imdIs0(), 0.1 ether, market.imdIs0() ? market.SQRT_LOWER() + 1 : market.SQRT_UPPER() - 1);
        uint256 bought = token.balanceOf(address(attacker));
        burn0 = miner.totalFincrBurned();
        nextBid(2_000_000);
        uint256 manipulated = miner.totalFincrBurned() - burn0;
        assertLt(manipulated, baseline);
        attacker.trade(!market.imdIs0(), bought, market.imdIs0() ? market.SQRT_UPPER() - 1 : market.SQRT_LOWER() + 1);
        emit log_named_uint("Fork baseline victim FINCR burn", baseline);
        emit log_named_uint("Fork sandwiched victim FINCR burn", manipulated);
        emit log_named_uint(
            "Fork attacker final IMD (started 1 IMD)", IERC20(miner.WORK_ASSET()).balanceOf(address(attacker))
        );
        assertEq(IERC20(miner.WORK_ASSET()).balanceOf(address(miner)), miner.imdLiability());
    }

    function testTask23InitialFeeClaimsCannotDecreasePrincipalAndOnlyRequesterChangesFees() public {
        (IProjectFactory.PoolKey memory k, int24 lower, int24 upper,) = FACTORY.positionOf(number);
        bytes32 slot = positionSlot(address(FACTORY), lower, upper, 0);
        uint128 principal = uint128(uint256(IV4Market(market.MANAGER()).extsload(slot)));

        FACTORY.claimFees(number);
        assertEq(uint128(uint256(IV4Market(market.MANAGER()).extsload(slot))), principal);
        vm.prank(address(777));
        vm.expectRevert();
        FACTORY.setRequester(number, address(778));
        FACTORY.setRequester(number, address(779));
        (,,, address next) = FACTORY.positionOf(number);
        assertEq(next, address(779));
        address[3] memory roles =
            [FACTORY.deployer(), address(779), address(0x2BAD8182C09F50c8318d769245beA52C32Be46CD)];
        for (uint256 i; i < roles.length; i++) {
            vm.prank(roles[i]);
            (bool ok,) = address(FACTORY)
                .call(abi.encodeWithSignature("removeLiquidity(uint64,uint128,address)", number, principal, roles[i]));
            assertFalse(ok);
            vm.prank(roles[i]);
            (ok,) = address(FACTORY).call(abi.encodeWithSignature("upgradeTo(address)", roles[i]));
            assertFalse(ok);
        }
        // Even a test-only impersonation of the factory cannot start an unscoped callback.
        IV4Market manager = IV4Market(market.MANAGER());
        vm.prank(address(FACTORY));
        vm.expectRevert();
        manager.unlock("crafted withdrawal");
        assertEq(uint128(uint256(IV4Market(market.MANAGER()).extsload(slot))), principal);
        assertEq(k.hooks, market.GUARD());
    }

    function testTask23ReceiverThirteenWordEncodingAndSourcePins() public {
        bytes memory args = receiver.minerArguments(address(token));
        assertEq(args.length, 416);
        assertEq(
            args,
            abi.encode(
                Mining.Config(
                    address(token),
                    miner.WORK_ASSET(),
                    1e27,
                    0.1 ether,
                    0.1 ether,
                    address(receiver),
                    OPS,
                    address(702),
                    keccak256("LOCAL ONLY"),
                    1 days,
                    1 days,
                    1 hours,
                    0.1 ether
                )
            )
        );
        assertTrue(receiver.bootstrapped());
        assertTrue(miner.armed());
        assertEq(market.vault(), address(miner));
        assertEq(miner.genesis(), block.timestamp);
        vm.prank(BOOTSTRAP);
        vm.expectRevert(Receiver.Replay.selector);
        receiver.bootstrap(number, "", "", keccak256("replay"));
        assertLt(type(Mining).creationCode.length + 416, 49153);
        assertLt(address(miner).code.length, 24577);
        assertLt(address(market).code.length, 24577);
    }
}
