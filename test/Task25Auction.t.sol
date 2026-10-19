// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MiningTestBase} from "./helpers/MiningTestBase.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {FinancierMining} from "../src/FinancierMining.sol";

/// Exact founder-approved targets; synthetic local ERC20 balances only.
contract Task25AuctionTest is MiningTestBase {
    event Takeover(
        uint256 indexed epoch,
        address indexed outgoing,
        address indexed incoming,
        uint256 paid,
        uint256 nextResetPrice,
        uint256 timestamp
    );

    function setUp() public override {
        super.setUp();
        miner = newMiner(10 ether, 0.5 ether);
        fundAndArm(miner);
        prepare(alice, miner);
        prepare(bob, miner);
    }

    function testApprovedGenesisDecayStartsAtArmWithoutPreMining() public {
        uint256 opened = miner.auctionStart();
        assertEq(opened, block.timestamp);
        assertEq(miner.currentPrice(), 10 ether);
        vm.warp(opened + 1800);
        assertEq(miner.currentPrice(), 5.25 ether);
        assertEq(miner.genesis(), 0);
        assertEq(miner.elapsed(), 0);
        assertEq(miner.financierLiability(), 0);
        assertEq(miner.agentReserved(), 0);
        vm.warp(opened + 3599);
        assertEq(miner.currentPrice(), 10 ether - uint256(9.5 ether) * 3599 / 3600);
        vm.warp(opened + 3600);
        assertEq(miner.currentPrice(), 0.5 ether);
        vm.warp(opened + 100 days);
        assertEq(miner.currentPrice(), 0.5 ether);
        take(alice);
        assertEq(miner.genesis(), block.timestamp);
        assertEq(miner.claimableFincr(alice), 0);
        assertEq(miner.workBudget(), 0.425 ether);
        assertEq(miner.resetPrice(), 10 ether);
        assertSolvent();
    }

    function testNoPreArmDecayAndFirstBidUsesActualLivePrice() public {
        fincr = new MockToken();
        fincr.mint(address(this), SUPPLY);
        FinancierMining other = newMiner(10 ether, 0.5 ether);
        vm.warp(block.timestamp + 9 days);
        assertEq(other.currentPrice(), 10 ether);
        assertEq(other.auctionStart(), 0);
        fundAndArm(other);
        prepare(alice, other);
        vm.warp(block.timestamp + 1800);
        vm.prank(alice);
        other.bid(0, 10 ether, block.timestamp);
        assertEq(other.totalBidVolume(), 5.25 ether);
        assertEq(other.resetPrice(), 10 ether);
    }

    function testFixedTenResetAndSameBlockCompetitorsStale() public {
        take(alice);
        assertEq(miner.totalBidVolume(), 10 ether);
        assertEq(miner.workBudget(), 8.5 ether);
        assertEq(miner.currentPrice(), 10 ether);
        take(bob);
        assertEq(miner.currentPrice(), 10 ether);
        assertEq(miner.claimableFincr(alice), 0);
        vm.expectRevert(FinancierMining.StaleEpoch.selector);
        vm.prank(alice);
        miner.bid(1, 40 ether, block.timestamp);
        vm.warp(block.timestamp + 3600);
        assertEq(miner.currentPrice(), 0.5 ether); // Same floor every epoch.
        take(alice);
        assertEq(miner.resetPrice(), 10 ether);
        assertSolvent();
    }

    function testSuccessiveTenHalfNearOneAndFloorEventsAndIndependentClaims() public {
        uint256 start = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit Takeover(1, address(0), alice, 10 ether, 10 ether, start);
        take(alice);
        vm.warp(start + 1800);
        vm.expectEmit(true, true, true, true);
        emit Takeover(2, alice, bob, 5.25 ether, 10 ether, block.timestamp);
        take(bob);
        uint256 aliceEarned = miner.claimableFincr(alice);
        assertGt(aliceEarned, 0);
        uint256 nextStart = block.timestamp;
        vm.warp(nextStart + 3410);
        assertEq(miner.currentPrice(), 1_001388888888888889);
        vm.expectRevert(FinancierMining.PriceExceeded.selector);
        vm.prank(alice);
        miner.bid(2, 1 ether, block.timestamp);
        vm.warp(nextStart + 3411);
        assertEq(miner.currentPrice(), 0.99875 ether);
        vm.expectEmit(true, true, true, true);
        emit Takeover(3, bob, alice, 0.99875 ether, 10 ether, block.timestamp);
        vm.prank(alice);
        miner.bid(2, 1 ether, block.timestamp); // Max 1 IMD, never voluntary overpayment.
        uint256 bobEarned = miner.claimableFincr(bob);
        vm.warp(block.timestamp + 3600);
        vm.expectEmit(true, true, true, true);
        emit Takeover(4, alice, bob, 0.5 ether, 10 ether, block.timestamp);
        take(bob);
        uint256 aliceTotal = miner.claimableFincr(alice);
        assertGt(aliceTotal, aliceEarned);
        vm.prank(alice);
        assertEq(miner.claimFincr(), aliceTotal);
        vm.prank(bob);
        assertEq(miner.claimFincr(), bobEarned);
        (, uint256 f,) = miner.cumulativeAt(block.timestamp - start);
        assertEq(aliceTotal + bobEarned, f);
        assertEq(miner.totalBidVolume(), 16.74875 ether);
        assertEq(miner.resetPrice(), 10 ether);
        assertSolvent();
    }

    function testRepeatedFloorBidsRestartHourWithoutMinimumTenure() public {
        take(alice);
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 3600);
            uint256 oldWork = miner.workBudget();
            take(bob);
            assertEq(miner.workBudget() - oldWork, 0.025 ether);
            assertEq(miner.currentPrice(), 10 ether);
            uint256 epochBefore = miner.epoch();
            take(alice); // Immediate challenger may pay 10; no minimum tenure is invented.
            assertEq(miner.epoch(), epochBefore + 1);
            assertEq(miner.currentPrice(), 10 ether);
            assertSolvent();
        }
    }

    function testSameBlockRepeatedTenBidsNeverEscalateOrEmit() public {
        for (uint256 i; i < 100; ++i) {
            take(i % 2 == 0 ? alice : bob);
            assertEq(miner.currentPrice(), 10 ether);
        }
        assertEq(miner.totalBidVolume(), 1000 ether);
        assertEq(miner.financierLiability(), 0);
        assertEq(miner.agentReserved(), 0);
        assertSolvent();
    }

    function testApprovedCurveAndProtectedStreamsAtAllBoundaries() public view {
        (uint256 launch,,) = miner.cumulativeAt(42 days);
        assertEq(launch, 240_000_000 ether);
        (uint256 gross, uint256 f, uint256 a) = miner.cumulativeAt(365 days);
        assertEq(gross, 400_000_000 ether);
        assertEq(f, 320_000_000 ether);
        assertEq(a, 80_000_000 ether);
        (uint256 afterEnd,,) = miner.cumulativeAt(366 days);
        assertEq(afterEnd, gross);
        (uint256 e1,,) = miner.cumulativeAt(14 days);
        (uint256 e2,,) = miner.cumulativeAt(28 days);
        assertLe(launch * 4 - e1 * 7, 7); // Global floor, no per-era overpayment.
        assertLe(launch * 6 - e2 * 7, 7);
    }

    function testFuzzGenesisAndEpochPricesNeverRise(uint32 first, uint32 second) public {
        uint256 t1 = bound(first, 0, 3600);
        uint256 t2 = bound(second, t1, 30 days);
        uint256 start = miner.auctionStart();
        vm.warp(start + t1);
        uint256 earlier = miner.currentPrice();
        vm.warp(start + t2);
        assertLe(miner.currentPrice(), earlier);
        assertGe(miner.currentPrice(), 0.5 ether);
        take(alice);
        uint256 reset = miner.resetPrice();
        uint256 epochStart = block.timestamp;
        vm.warp(epochStart + t1);
        earlier = miner.currentPrice();
        vm.warp(epochStart + t2);
        assertLe(miner.currentPrice(), earlier);
        assertGe(miner.currentPrice(), 0.5 ether);
        assertEq(miner.currentPrice(), t2 >= 3600 ? 0.5 ether : reset - (reset - 0.5 ether) * t2 / 3600);
        assertSolvent();
    }
}
