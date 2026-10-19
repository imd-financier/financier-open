// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task23Base, IERC20} from "./helpers/Task23Base.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract Task25FundingTest is Task23Base {
    function testWorkFundingHasNoBidRewardOrAuthorityRights() public {
        uint256 work = miner.workBudget();
        uint256 volume = miner.totalBidVolume();
        uint256 reserve = token.balanceOf(address(miner));
        uint256 epoch = miner.epoch();
        deal(IMD, BOB, 1 ether);
        vm.startPrank(BOB);
        IERC20(IMD).approve(address(miner), 1 ether);
        miner.fundWork(1 ether);
        vm.stopPrank();
        assertEq(miner.totalWorkFunding(), 1 ether);
        assertEq(miner.workBudget(), work + 1 ether);
        assertEq(miner.totalBidVolume(), volume);
        assertEq(miner.epoch(), epoch);
        assertEq(token.balanceOf(address(miner)), reserve);
        assertEq(miner.claimableFincr(BOB), 0);
        assertEq(miner.totalBidVolume() + miner.totalWorkFunding(), miner.totalImdPaid() + miner.imdLiability());
        assertEq(IERC20(IMD).balanceOf(address(miner)), miner.imdLiability());
    }

    function testFundingRejectsShortTransferAndReentrancy() public {
        MockToken implementation = new MockToken();
        vm.etch(IMD, address(implementation).code); // Explicit synthetic adversarial ERC20 runtime.
        MockToken imd = MockToken(IMD);
        imd.setBlocked(false);
        imd.setCallback(address(0), "");
        imd.mint(BOB, 1 ether);
        vm.prank(BOB);
        imd.approve(address(miner), 1 ether);
        imd.setMode(2);
        uint256 work = miner.workBudget();
        vm.prank(BOB);
        vm.expectRevert();
        miner.fundWork(1 ether);
        assertEq(miner.workBudget(), work);
        assertEq(miner.totalWorkFunding(), 0);
        imd.setMode(0);
        imd.setCallback(address(miner), abi.encodeCall(miner.fundWork, (1)));
        vm.prank(BOB);
        miner.fundWork(1 ether);
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSuccess());
        assertEq(miner.totalWorkFunding(), 1 ether);
    }
}
