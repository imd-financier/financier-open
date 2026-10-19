// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MiningTestBase} from "./helpers/MiningTestBase.sol";
import {FinancierMining} from "../src/FinancierMining.sol";

contract AuctionTest is MiningTestBase {
    function testGenesisNoHeadStartWithEqualOpeningAndFloor() public {
        vm.warp(block.timestamp + 100 days);
        assertEq(miner.genesis(), 0);
        assertEq(miner.currentPrice(), 1 ether);
        assertEq(miner.financierLiability(), 0);
        assertEq(miner.agentReserved(), 0);
        take(alice);
        assertEq(miner.iFinancier(), alice);
        assertEq(miner.epoch(), 1);
        assertEq(miner.genesis(), block.timestamp);
        assertEq(miner.claimableFincr(alice), 0);
        assertEq(miner.workBudget(), 0.85 ether);
        assertEq(miner.totalOutgoingCredits(), 0);
        assertEq(miner.buybackBudget(), 0.075 ether);
        assertEq(miner.liquidityBudget(), 0.0375 ether);
        assertEq(miner.operationsBudget(), 0.0375 ether);
        assertEq(miner.currentPrice(), 1 ether);
        assertSolvent();
    }

    function testFloorQuotesAtZeroTenThirtySixtyMinutes() public {
        take(alice);
        uint256 start = block.timestamp;
        assertEq(miner.currentPrice(), 1 ether);
        vm.warp(start + 10 minutes);
        assertEq(miner.currentPrice(), 1 ether);
        vm.warp(start + 30 minutes);
        assertEq(miner.currentPrice(), 1 ether);
        vm.warp(start + 60 minutes);
        assertEq(miner.currentPrice(), 1 ether);
        vm.warp(start + 999 days);
        assertEq(miner.currentPrice(), 1 ether);
    }

    function testZeroTerminalAndZeroCaptureResetsImmutableOpening() public {
        miner = newMiner(1 ether, 0);
        fundAndArm(miner);
        prepare(alice, miner);
        prepare(bob, miner);
        take(alice);
        uint256 start = block.timestamp;
        vm.warp(start + 10 minutes);
        assertEq(miner.currentPrice(), 1 ether - uint256(1 ether) / 6);
        vm.warp(start + 30 minutes);
        assertEq(miner.currentPrice(), 0.5 ether);
        vm.warp(start + 60 minutes);
        assertEq(miner.currentPrice(), 0);
        uint256 before = imd.balanceOf(bob);
        take(bob);
        assertEq(imd.balanceOf(bob), before);
        assertEq(miner.outgoingCredit(alice), 0);
        assertEq(miner.resetPrice(), 1 ether);
        assertGt(miner.claimableFincr(alice), 0);
        assertSolvent();
    }

    function testAcceptedQuotesResetToImmutableOpening() public {
        take(alice); // Fixed opening remains 1 IMD in this generic fixture.
        take(bob);
        assertEq(miner.currentPrice(), 1 ether);
        assertEq(miner.outgoingCredit(alice), 0.8 ether);
        vm.warp(block.timestamp + 1 hours); // 1 < historical 2
        take(carol);
        assertEq(miner.currentPrice(), 1 ether);
        assertEq(miner.outgoingCredit(bob), 0.8 ether);
        assertSolvent();
    }

    function testSameBlockSelfTakeoversNoEmissionsAndPartialRecovery() public {
        take(alice);
        uint256 g = miner.genesis();
        for (uint256 i; i < 8; ++i) {
            take(alice);
        }
        assertEq(miner.genesis(), g);
        assertEq(miner.claimableFincr(alice), 0);
        assertEq(miner.agentReserved(), 0);
        assertEq(miner.epoch(), 9);
        uint256 credit = miner.outgoingCredit(alice);
        vm.prank(alice);
        assertEq(miner.claimImd(), credit);
        assertLt(credit, miner.totalBidVolume());
        assertSolvent();
    }

    function testStaleDeadlineAndSlippageRollback() public {
        take(alice);
        uint256 volume = miner.totalBidVolume();
        vm.expectRevert(FinancierMining.StaleEpoch.selector);
        vm.prank(bob);
        miner.bid(0, 99 ether, block.timestamp);
        vm.expectRevert(FinancierMining.Expired.selector);
        vm.prank(bob);
        miner.bid(1, 99 ether, block.timestamp - 1);
        vm.expectRevert(FinancierMining.PriceExceeded.selector);
        vm.prank(bob);
        miner.bid(1, 1 ether - 1, block.timestamp);
        assertEq(miner.totalBidVolume(), volume);
        assertEq(miner.iFinancier(), alice);
        assertSolvent();
    }

    function testMaxPriceIsNotVoluntaryOverpayment() public {
        vm.prank(alice);
        miner.bid(0, 10 ether, block.timestamp);
        assertEq(miner.totalBidVolume(), 1 ether);
        assertEq(miner.resetPrice(), 1 ether);
    }

    function testUnauthorizedArmingMissingFundingAndOneShot() public {
        FinancierMining other = newMiner(1 ether, 0);
        vm.expectRevert(FinancierMining.NotArmed.selector);
        other.bid(0, 1 ether, block.timestamp);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        vm.prank(alice);
        other.arm();
        vm.expectRevert(FinancierMining.Unfunded.selector);
        other.arm();
        assertTrue(fincr.transfer(address(other), RESERVE - 1));
        vm.expectRevert(FinancierMining.Unfunded.selector);
        other.arm();
        assertTrue(fincr.transfer(address(other), 1));
        other.arm();
        vm.expectRevert(FinancierMining.AlreadyArmed.selector);
        other.arm();
        assertEq(other.genesis(), 0);
    }

    function testFundingRecheckedAtFirstBid() public {
        fincr.confiscate(address(miner), 1);
        vm.expectRevert(FinancierMining.Unfunded.selector);
        vm.prank(alice);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.epoch(), 0);
        assertEq(miner.totalBidVolume(), 0);
    }

    function testSupplyMismatch() public {
        FinancierMining other = newMiner(1 ether, 0);
        fincr.mint(alice, 1);
        vm.expectRevert(FinancierMining.SupplyMismatch.selector);
        other.arm();
    }

    function testInvalidConfiguration() public {
        vm.expectRevert(FinancierMining.InvalidConfiguration.selector);
        new FinancierMining(address(fincr), address(fincr), SUPPLY, 1 ether, 0, address(this), ops);
        vm.expectRevert(FinancierMining.InvalidConfiguration.selector);
        new FinancierMining(address(fincr), address(imd), SUPPLY, 1, 2, address(this), ops);
        vm.expectRevert(FinancierMining.InvalidConfiguration.selector);
        new FinancierMining(address(fincr), address(imd), 101, 1, 0, address(this), ops);
    }

    function testResetBoundDoesNotOverflow() public {
        miner = newMiner(type(uint192).max, 0);
        fundAndArm(miner);
        imd.mint(alice, type(uint192).max);
        vm.prank(alice);
        imd.approve(address(miner), type(uint256).max);
        take(alice);
        assertEq(miner.resetPrice(), type(uint192).max);
        assertSolvent();
    }

    function testFuzzQuoteNeverBelowFloorAndCorrectRounding(uint192 start, uint192 floor, uint32 delta) public {
        uint256 initial = bound(uint256(start), 1, type(uint192).max);
        uint256 terminal = bound(uint256(floor), 0, initial);
        FinancierMining other = newMiner(initial, terminal);
        fundAndArm(other);
        imd.mint(bob, initial);
        vm.prank(bob);
        imd.approve(address(other), initial);
        vm.prank(bob);
        other.bid(0, initial, block.timestamp);
        uint256 reset = other.resetPrice();
        vm.warp(block.timestamp + uint256(delta));
        uint256 dt = delta > 3600 ? 3600 : delta;
        assertEq(other.currentPrice(), reset - (reset - terminal) * dt / 3600);
        assertGe(other.currentPrice(), terminal);
        assertLe(other.currentPrice(), reset);
    }
}
