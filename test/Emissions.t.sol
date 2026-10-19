// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MiningTestBase} from "./helpers/MiningTestBase.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {EmissionSchedule} from "../src/EmissionSchedule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FINCR} from "../src/FINCR.sol";

contract CurveHarness {
    function cumulative(uint256 reserve, uint256 t) external pure returns (uint256, uint256, uint256) {
        (uint256 f, uint256 a) = EmissionSchedule.split(reserve, t);
        return (f + a, f, a);
    }
}

contract EmissionsTest is MiningTestBase {
    struct Fixture {
        uint256 agent;
        uint256 elapsed;
        uint256 financier;
        uint256 gross;
        uint256 supply;
    }

    function testIndependentPythonFixturesIncludingTinyAndMaxSupply() public {
        Fixture[] memory rows = abi.decode(vm.parseJson(vm.readFile("test/fixtures/emissions.json")), (Fixture[]));
        CurveHarness harness = new CurveHarness();
        assertEq(rows.length, 196);
        for (uint256 i; i < rows.length; ++i) {
            Fixture memory r = rows[i];
            (uint256 e, uint256 f, uint256 a) = harness.cumulative(Math.mulDiv(r.supply, 2, 5), r.elapsed);
            assertEq(e, r.gross);
            assertEq(f, r.financier);
            assertEq(a, r.agent);
            assertEq(e, f + a);
            if (r.supply == SUPPLY) {
                (uint256 liveE, uint256 liveF, uint256 liveA) = miner.cumulativeAt(r.elapsed);
                assertEq(e, liveE);
                assertEq(f, liveF);
                assertEq(a, liveA);
            }
        }
    }

    function testExactWeightsBoundariesAndNoTerminalLump() public view {
        uint256 fast = RESERVE * 3 / 5;
        (uint256 e14,,) = miner.cumulativeAt(14 days);
        assertEq(e14, fast * 4 / 7);
        (uint256 e28,,) = miner.cumulativeAt(28 days);
        assertEq(e28, fast * 6 / 7);
        (uint256 e42,,) = miner.cumulativeAt(42 days);
        assertEq(e42, fast);
        (uint256 e43,,) = miner.cumulativeAt(43 days);
        assertEq(e43, fast + (RESERVE - fast) / 323);
        (uint256 eEnd, uint256 fEnd, uint256 aEnd) = miner.cumulativeAt(365 days);
        assertEq(eEnd, RESERVE);
        assertEq(fEnd, RESERVE * 4 / 5);
        assertEq(aEnd, RESERVE / 5);
        (uint256 beforeEnd,,) = miner.cumulativeAt(365 days - 1);
        assertLe(eEnd - beforeEnd, (RESERVE - fast) / (323 days) + 1);
        (uint256 afterEnd,,) = miner.cumulativeAt(type(uint256).max);
        assertEq(afterEnd, RESERVE);
    }

    function testActiveFormerAndFinalClaimsIndependentAcrossEveryBoundary() public {
        take(alice);
        uint256 g = miner.genesis();
        vm.warp(g + 14 days);
        vm.prank(alice);
        uint256 a1 = miner.claimFincr();
        assertEq(miner.iFinancier(), alice);
        vm.warp(g + 28 days);
        take(bob);
        vm.prank(alice);
        uint256 a2 = miner.claimFincr();
        (, uint256 f28,) = miner.cumulativeAt(28 days);
        assertEq(a1 + a2, f28);
        vm.warp(g + 42 days);
        vm.prank(bob);
        uint256 b1 = miner.claimFincr();
        vm.warp(g + 365 days);
        vm.prank(bob);
        uint256 b2 = miner.claimFincr();
        assertEq(a1 + a2 + b1 + b2, RESERVE * 4 / 5);
        vm.warp(g + 10000 days);
        vm.prank(bob);
        assertEq(miner.claimFincr(), 0);
        assertEq(miner.agentReserved(), RESERVE / 5);
        assertEq(miner.unscheduledReserve(), 0);
        assertEq(miner.financierLiability(), 0);
        assertEq(miner.genesis(), g);
        assertSolvent();
    }

    function testLongInactivityCannotFreezeLaunchRateAndLastHolderCanClaim() public {
        take(alice);
        vm.warp(block.timestamp + 400 days);
        vm.prank(alice);
        assertEq(miner.claimFincr(), 320_000_000 ether);
        assertEq(miner.epoch(), 1);
        assertEq(fincr.balanceOf(address(miner)), 80_000_000 ether);
        take(bob);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        assertEq(miner.claimFincr(), 0);
        assertSolvent();
    }

    function testManyTinyTenuresAndClaimsConserveRounding() public {
        take(alice);
        uint256 g = miner.genesis();
        uint256 total;
        for (uint256 i = 1; i <= 100; ++i) {
            vm.warp(g + i);
            address previous = miner.iFinancier();
            // At positive floor, avoiding explosive same-block price growth here.
            vm.prank(previous);
            total += miner.claimFincr();
        }
        (, uint256 f, uint256 a) = miner.cumulativeAt(100);
        assertEq(total, f);
        assertEq(miner.agentReserved(), a);
        assertSolvent();
    }

    function testSplitTenuresVersusUninterruptedAcrossHalvings() public {
        take(alice);
        uint256 g = miner.genesis();
        uint256[10] memory times =
            [uint256(1), 3600, 14 days - 1, 14 days, 14 days + 1, 28 days, 42 days - 1, 42 days, 365 days, 500 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(g + times[i]);
            take(i % 2 == 0 ? bob : alice);
            vm.prank(alice);
            miner.claimFincr();
            vm.prank(bob);
            miner.claimFincr();
        }
        assertEq(miner.totalFincrPaid(), RESERVE * 4 / 5);
        assertEq(miner.genesis(), g);
        assertSolvent();
    }

    function testAgentIsolationAndIntervalsNotPaymentAuthorization() public {
        take(alice);
        vm.warp(block.timestamp + 10 days);
        uint256 a = miner.agentReserved();
        assertEq(miner.agentAllocation(0, 10 days), a);
        assertEq(miner.agentAllocation(0, 3 days) + miner.agentAllocation(3 days, 10 days), a);
        vm.expectRevert(FinancierMining.InvalidInterval.selector);
        miner.agentAllocation(1, 0);
        vm.prank(alice);
        miner.claimFincr();
        assertEq(miner.agentReserved(), a);
        assertEq(miner.requiredFincrCustody(), a + miner.unscheduledReserve());
        (bool ok,) = address(miner).call(abi.encodeWithSignature("claimAgent(uint256)", a));
        assertFalse(ok);
    }

    function testFincrBurnReducesSupplyAndCannotGriefArming() public {
        FINCR token = new FINCR(SUPPLY);
        FinancierMining other =
            new FinancierMining(address(token), address(imd), SUPPLY, 1 ether, 0, address(this), ops);
        assertTrue(token.transfer(address(other), RESERVE));
        assertTrue(token.transfer(alice, 1 ether));
        vm.prank(alice);
        token.burn(1 ether);
        assertEq(token.totalSupply(), SUPPLY - 1 ether);
        assertEq(token.initialSupply(), SUPPLY);
        other.arm();
        assertTrue(other.armed());
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", address(other), 1));
        assertFalse(ok);
    }

    function testFuzzGlobalConservationMonotonicityAndPartitions(uint256 seed, uint32 x, uint32 y, uint32 z)
        public
        pure
    {
        uint256 supply = bound(seed, 1, type(uint256).max / 100) * 100;
        uint256 reserve = Math.mulDiv(supply, 2, 5);
        uint256 a = uint256(x) % (730 days);
        uint256 b = uint256(y) % (730 days);
        uint256 c = uint256(z) % (730 days);
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        (uint256 f0, uint256 a0) = EmissionSchedule.split(reserve, a);
        (uint256 f1, uint256 a1) = EmissionSchedule.split(reserve, b);
        (uint256 f2, uint256 a2) = EmissionSchedule.split(reserve, c);
        assertLe(f2 + a2, reserve);
        assertGe(f1, f0);
        assertGe(f2, f1);
        assertGe(a1, a0);
        assertGe(a2, a1);
        assertEq((f1 - f0) + (f2 - f1), f2 - f0);
        assertEq((a1 - a0) + (a2 - a1), a2 - a0);
        assertEq(f2, Math.mulDiv(f2 + a2, 4, 5));
        assertEq(EmissionSchedule.gross(reserve, type(uint256).max), reserve);
    }
}
