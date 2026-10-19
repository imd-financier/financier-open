// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FinancierMining} from "../../src/FinancierMining.sol";
import {MockToken} from "./MockToken.sol";

abstract contract MiningTestBase is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant RESERVE = 400_000_000 ether;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA701);
    address internal ops = address(0x0F5);
    MockToken internal fincr;
    MockToken internal imd;
    FinancierMining internal miner;

    function setUp() public virtual {
        vm.warp(1_000_000);
        fincr = new MockToken();
        imd = new MockToken();
        fincr.mint(address(this), SUPPLY);
        miner = newMiner(1 ether, 1 ether);
        fundAndArm(miner);
        prepare(alice, miner);
        prepare(bob, miner);
        prepare(carol, miner);
    }

    function newMiner(uint256 initial, uint256 floor) internal returns (FinancierMining) {
        return new FinancierMining(address(fincr), address(imd), SUPPLY, initial, floor, address(this), ops);
    }

    function fundAndArm(FinancierMining target) internal {
        assertTrue(fincr.transfer(address(target), RESERVE));
        target.arm();
    }

    function prepare(address actor, FinancierMining target) internal {
        imd.mint(actor, 1e50);
        vm.prank(actor);
        imd.approve(address(target), type(uint256).max);
    }

    function take(address actor) internal {
        uint256 e = miner.epoch();
        uint256 p = miner.currentPrice();
        vm.prank(actor);
        miner.bid(e, p, block.timestamp);
    }

    function assertSolvent() internal view {
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(miner.totalBidVolume(), miner.totalImdPaid() + miner.imdLiability());
        assertEq(fincr.balanceOf(address(miner)), miner.requiredFincrCustody());
        assertEq(
            miner.requiredFincrCustody(),
            miner.financierLiability() + miner.agentReserved() + miner.unscheduledReserve()
        );
    }
}
