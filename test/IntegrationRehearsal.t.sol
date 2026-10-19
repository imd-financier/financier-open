// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IntegrationBase} from "./helpers/IntegrationBase.sol";
import {IAgentWorkVerifier} from "../src/interfaces/IAgentWorkVerifier.sol";

contract IntegrationRehearsalTest is IntegrationBase {
    function testLocalLaunchFundingTakeoverAndGeneratedAgentSettlement() public {
        deployIntegration(false);
        assertEq(token.balanceOf(address(forwarder)), RESERVE);
        assertFalse(miner.armed());
        forwarder.forward(tokenCode, minerCode);
        assertTrue(miner.armed());
        assertEq(miner.epoch(), 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        uint256 genesis = miner.genesis();
        vm.warp(genesis + 10 minutes);
        uint256 price = miner.currentPrice();
        vm.prank(BOB);
        miner.bid(1, price, block.timestamp);
        vm.startPrank(ALICE);
        uint256 f = miner.claimFincr();
        uint256 imdPayout = miner.claimImd();
        vm.stopPrank();
        assertGt(f, 0);
        assertEq(imdPayout, price - price * 500 / 10000 - price * 750 / 10000 - 2 * (price * 375 / 10000));
        vm.warp(genesis + 1 days);
        IAgentWorkVerifier.Contribution[] memory accepted = contributions(0, 2);
        rounds.finalize(0, accepted, approveRound(0, accepted));
        for (uint256 i; i < 2; ++i) {
            vm.prank(accepted[i].beneficiary);
            rounds.claim(0);
        }
        emit log_named_uint("First agent round FINCR base units paid (GENERATED proofs)", miner.totalAgentPaid());
        emit log_named_uint("Outgoing financier FINCR base units claimed", f);
        emit log_named_uint("Outgoing financier IMD base units claimed", imdPayout);
        vm.warp(genesis + 366 days);
        vm.prank(BOB);
        miner.claimFincr();
        assertEq(miner.totalFincrPaid(), 320_000_000 ether);
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid() + miner.totalFincrPaid(), RESERVE);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
    }
}
