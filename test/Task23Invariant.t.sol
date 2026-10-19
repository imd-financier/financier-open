// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task23Base, V4AttackActor, Mining, Market, IERC20} from "./helpers/Task23Base.sol";
import {Test} from "forge-std/Test.sol";

contract MarketHandler is Test {
    Mining public miner;
    V4AttackActor public actor;

    constructor(Mining m, V4AttackActor a) {
        miner = m;
        actor = a;
    }

    function bid(uint256 who, uint32 time, bool lowGas) external {
        vm.warp(block.timestamp + uint256(time) % 2 days);
        uint256 e = miner.epoch();
        uint256 p = miner.currentPrice();
        vm.prank(who % 2 == 0 ? address(101) : address(102));
        miner.bid{gas: lowGas ? 450_000 : 2_000_000}(e, p, block.timestamp);
    }

    function fundWork(uint256 who, uint256 amount) external {
        amount = bound(amount, 1, 0.1 ether);
        address payer = who % 2 == 0 ? address(101) : address(102);
        vm.prank(payer);
        miner.fundWork(amount);
    }

    function claim(uint256 who) external {
        address a = who % 2 == 0 ? address(101) : address(102);
        vm.prank(a);
        miner.claimFincr();
        vm.prank(a);
        miner.claimImd();
        vm.prank(address(105));
        miner.claimOperations();
    }

    function manipulate(uint256 amount, bool direction) external {
        amount = bound(amount, 1e20, 1e24);
        try actor.trade(direction, amount, direction ? uint160(1 << 95) : uint160(2 << 96)) {} catch {}
    }
}

contract Task23InvariantTest is Task23Base {
    function setUp() public override {
        super.setUp();
        assertGt(miner.totalFincrBurned(), 0);
        assertEq(market.positions(), 1);
        MarketHandler handler = new MarketHandler(miner, actor);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.bid.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.manipulate.selector;
        selectors[3] = handler.fundWork.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantDisjointBucketsAndSolvency() public view {
        checkSolvent();
    }

    function invariantSupplyBurnOnlyAndReserveConservation() public view {
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
        assertEq(token.balanceOf(address(market)), market.strandedFincrDust());
    }

    function invariantEverySupplementalPositionPersistsAndSumMatches() public view {
        assertGt(market.positions(), 0);
        uint256 sum;
        for (uint256 i; i < market.positions(); i++) {
            bytes32 salt = keccak256(abi.encode("FINANCIER permanent supplemental LP v1", i));
            uint128 liq = market.positionLiquidity(salt);
            assertGt(liq, 0);
            sum += liq;
        }
        assertEq(sum, market.totalLiquidity());
    }
}
