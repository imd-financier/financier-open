// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {MiningTestBase} from "./helpers/MiningTestBase.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CustodyTest is MiningTestBase {
    function testFuzzWaterfallExactAndGenesisSeparate(uint128 input) public {
        uint256 price = bound(uint256(input), 1, type(uint128).max);
        miner = newMiner(price, price);
        fundAndArm(miner);
        prepare(alice, miner);
        prepare(bob, miner);
        take(alice);
        uint256 work = price * 500 / 10000;
        uint256 buy = price * 750 / 10000;
        uint256 lp = price * 375 / 10000;
        uint256 op = lp;
        uint256 outgoing = price - work - buy - lp - op;
        assertEq(miner.workBudget(), work + outgoing);
        assertEq(miner.totalOutgoingCredits(), 0);
        vm.warp(block.timestamp + 1 hours);
        take(bob);
        assertEq(miner.workBudget(), 2 * work + outgoing);
        assertEq(miner.outgoingCredit(alice), outgoing);
        assertEq(miner.buybackBudget(), 2 * buy);
        assertEq(miner.liquidityBudget(), 2 * lp);
        assertEq(miner.operationsBudget(), 2 * op);
        assertSolvent();
    }

    function testIndependentImdAndOperationsClaimsNoDoublePay() public {
        take(alice);
        vm.warp(block.timestamp + 1 hours);
        take(bob);
        uint256 f = miner.claimableFincr(alice);
        uint256 imdOwed = miner.outgoingCredit(alice);
        vm.prank(alice);
        assertEq(miner.claimImd(), imdOwed);
        assertEq(miner.claimableFincr(alice), f);
        vm.prank(alice);
        assertEq(miner.claimImd(), 0);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        vm.prank(alice);
        miner.claimOperations();
        uint256 op = miner.operationsBudget();
        vm.prank(ops);
        assertEq(miner.claimOperations(), op);
        vm.prank(ops);
        assertEq(miner.claimOperations(), 0);
        assertSolvent();
    }

    function testUnknownWithdrawRescueAndUpgradeSelectorsFail() public {
        take(alice);
        (bool a,) = address(miner).call(abi.encodeWithSignature("withdraw(address,uint256)", address(imd), 1 ether));
        (bool b,) = address(miner).call(abi.encodeWithSignature("upgradeTo(address)", alice));
        (bool c,) = address(miner).call(abi.encodeWithSignature("setFinancier(address)", bob));
        assertFalse(a);
        assertFalse(b);
        assertFalse(c);
        assertEq(miner.iFinancier(), alice);
        assertSolvent();
    }

    function testBlockedImdClaimRetainsCredit() public {
        take(alice);
        take(bob);
        uint256 credit = miner.outgoingCredit(alice);
        imd.setBlocked(true);
        vm.expectRevert("blocked transfer");
        vm.prank(alice);
        miner.claimImd();
        assertEq(miner.outgoingCredit(alice), credit);
        assertEq(miner.totalImdPaid(), 0);
        imd.setBlocked(false);
        vm.prank(alice);
        miner.claimImd();
        assertSolvent();
    }

    function testBlockedFincrClaimRetainsAccrualAndCredit() public {
        take(alice);
        vm.warp(block.timestamp + 14 days);
        uint256 credit = miner.claimableFincr(alice);
        fincr.setBlocked(true);
        vm.expectRevert("blocked transfer");
        vm.prank(alice);
        miner.claimFincr();
        assertEq(miner.claimableFincr(alice), credit);
        assertEq(miner.totalFincrPaid(), 0);
        fincr.setBlocked(false);
        vm.prank(alice);
        assertEq(miner.claimFincr(), credit);
        assertSolvent();
    }

    function testNoAllowancePaymentFailsWithoutLiabilitiesOrGenesis() public {
        vm.prank(alice);
        imd.approve(address(miner), 0);
        vm.expectRevert();
        vm.prank(alice);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.epoch(), 0);
        assertEq(miner.genesis(), 0);
        assertEq(miner.imdLiability(), 0);
    }

    function testFalseReturnAndLyingTransferRejectPayment() public {
        imd.setMode(4);
        vm.expectRevert();
        vm.prank(alice);
        miner.bid(0, 1 ether, block.timestamp);
        imd.setMode(7);
        vm.expectRevert(FinancierMining.InexactTransfer.selector);
        vm.prank(alice);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.epoch(), 0);
        assertEq(miner.imdLiability(), 0);
    }

    function testFeeOnTransferAndExtraPayerDebitReject() public {
        for (uint256 m = 2; m <= 3; ++m) {
            imd.setMode(m);
            vm.expectRevert(FinancierMining.InexactTransfer.selector);
            vm.prank(alice);
            miner.bid(0, 1 ether, block.timestamp);
            assertEq(miner.epoch(), 0);
            assertEq(miner.totalBidVolume(), 0);
        }
    }

    function testNonReturningTokenSupportedOnBidAndClaims() public {
        imd.setMode(5);
        take(alice);
        take(bob);
        vm.prank(alice);
        assertGt(miner.claimImd(), 0);
        vm.warp(block.timestamp + 1 days);
        fincr.setMode(5);
        vm.prank(bob);
        assertGt(miner.claimFincr(), 0);
        assertSolvent();
    }

    function testTaxedOutgoingClaimsRejectAndPreserveBothAssets() public {
        take(alice);
        vm.warp(block.timestamp + 1 days);
        take(bob);
        uint256 i = miner.outgoingCredit(alice);
        uint256 f = miner.claimableFincr(alice);
        imd.setMode(2);
        fincr.setMode(3);
        vm.expectRevert(FinancierMining.InexactTransfer.selector);
        vm.prank(alice);
        miner.claimImd();
        vm.expectRevert(FinancierMining.InexactTransfer.selector);
        vm.prank(alice);
        miner.claimFincr();
        assertEq(miner.outgoingCredit(alice), i);
        assertEq(miner.claimableFincr(alice), f);
        assertSolvent();
    }

    function testReentrantBidAndCrossFunctionClaimBlocked() public {
        imd.setCallback(address(miner), abi.encodeCall(miner.bid, (1, type(uint256).max, block.timestamp)));
        take(alice);
        assertTrue(imd.callbackAttempted());
        assertFalse(imd.callbackSuccess());
        assertEq(bytes4(imd.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        imd.setCallback(address(miner), abi.encodeCall(miner.claimFincr, ()));
        take(bob);
        assertFalse(imd.callbackSuccess());
        assertEq(bytes4(imd.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.warp(block.timestamp + 1 days);
        fincr.setCallback(address(miner), abi.encodeCall(miner.claimFincr, ()));
        vm.prank(bob);
        miner.claimFincr();
        assertTrue(fincr.callbackAttempted());
        assertFalse(fincr.callbackSuccess());
        assertEq(bytes4(fincr.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertSolvent();
    }

    function testUnsuccessfulSuccessorCannotCreditOrReplaceIncumbent() public {
        take(alice);
        vm.warp(block.timestamp + 10 minutes);
        uint256 earned = miner.claimableFincr(alice);
        imd.setBlocked(true);
        vm.expectRevert("blocked transfer");
        vm.prank(bob);
        miner.bid(1, 2 ether, block.timestamp);
        assertEq(miner.epoch(), 1);
        assertEq(miner.iFinancier(), alice);
        assertEq(miner.outgoingCredit(alice), 0);
        assertEq(miner.fincrCredit(alice), 0);
        assertEq(miner.claimableFincr(alice), earned);
        assertSolvent();
    }

    function testBlockedOperationsClaimKeepsItsBudget() public {
        take(alice);
        uint256 budget = miner.operationsBudget();
        imd.setMode(4);
        vm.expectRevert();
        vm.prank(ops);
        miner.claimOperations();
        assertEq(miner.operationsBudget(), budget);
        assertEq(miner.totalImdPaid(), 0);
        assertSolvent();
    }

    function testUnsolicitedDonationsDoNotCreateClaimsOrMining() public {
        take(alice);
        uint256 required = miner.requiredFincrCustody();
        assertTrue(fincr.transfer(address(miner), 10 ether));
        vm.prank(bob);
        assertTrue(imd.transfer(address(miner), 10 ether));
        assertEq(miner.requiredFincrCustody(), required);
        assertEq(miner.claimableFincr(alice), 0);
        assertEq(fincr.balanceOf(address(miner)), required + 10 ether);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability() + 10 ether);
        vm.prank(bob);
        assertEq(miner.claimImd(), 0);
        vm.prank(bob);
        assertEq(miner.claimFincr(), 0);
    }
}
