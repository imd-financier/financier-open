// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FINCR} from "../src/FINCR.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {FinancierMiningWithSettlement as Mining} from "../src/FinancierMiningWithSettlement.sol";

/// Test-only token: incoming transferFrom is normal; outgoing transfer can be hostile.
contract OutgoingFaultToken is ERC20 {
    uint256 public fault;
    address public reentryTarget;
    bytes public reentryData;
    bool public attempted;
    bool public reentrySucceeded;
    constructor() ERC20("LOCAL", "LOCAL") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }

    function setFault(uint256 f) external {
        fault = f;
    }

    function setReentry(address t, bytes calldata d) external {
        reentryTarget = t;
        reentryData = d;
    }

    function transfer(address to, uint256 n) public override returns (bool) {
        if (fault == 1) revert("LOCAL outgoing blocked");
        if (fault == 2) return false;
        if (fault == 3) {
            _transfer(msg.sender, to, n - 1);
            return true;
        }
        if (fault == 4) {
            _transfer(msg.sender, to, n);
            _burn(msg.sender, 1);
            return true;
        }
        if (fault == 7) assembly { revert(0, 75000) }
        if (fault == 6) while (true) assembly { pop(keccak256(0, 32)) }
        _transfer(msg.sender, to, n);
        if (reentryTarget != address(0)) {
            attempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
        if (fault == 5) assembly { return(0, 0) }
        return true;
    }
}

contract AutoOutgoingTest is Test {
    FINCR f;
    OutgoingFaultToken imd;
    Mining m;
    address constant A = address(101);
    address constant B = address(102);

    function setUp() public {
        vm.warp(1_000_000);
        f = new FINCR(1e27);
        imd = new OutgoingFaultToken();
        m = make(1 ether, 1 ether);
        f.transfer(address(m), 4e26);
        m.arm();
        fund(A);
        fund(B);
    }

    function make(uint256 quote, uint256 floor) internal returns (Mining) {
        return new Mining(
            address(f),
            address(imd),
            1e27,
            quote,
            floor,
            address(this),
            address(105),
            address(702),
            keccak256("LOCAL policy"),
            1 days,
            1 days,
            1 hours
        );
    }

    function fund(address who) internal {
        imd.mint(who, 100 ether);
        vm.prank(who);
        imd.approve(address(m), type(uint256).max);
    }

    function bid(address who) internal {
        uint256 e = m.epoch();
        uint256 p = m.currentPrice();
        vm.prank(who);
        m.bid(e, p, block.timestamp);
    }

    function start() internal {
        bid(A);
        vm.warp(block.timestamp + 1 hours);
    }

    function solvent() internal view {
        assertEq(imd.balanceOf(address(m)), m.imdLiability());
        assertEq(m.totalBidVolume(), m.totalImdPaid() + m.imdLiability());
        assertEq(f.balanceOf(address(m)) + m.totalFincrPaid() + m.totalAgentPaid(), 4e26);
    }

    function testGenesisAndExactAutomaticPayoutNoDoubleClaim() public {
        start();
        assertEq(m.workBudget(), 0.85 ether);
        assertEq(m.totalImdPaid(), 0);
        uint256 before = imd.balanceOf(A);
        bid(B);
        assertEq(imd.balanceOf(A) - before, 0.8 ether);
        assertEq(m.totalImdPaid(), 0.8 ether);
        assertEq(m.outgoingCredit(A), 0);
        vm.prank(A);
        assertEq(m.claimImd(), 0);
        assertEq(m.workBudget(), 0.9 ether);
        assertEq(m.buybackBudget(), 0.15 ether);
        assertEq(m.liquidityBudget(), 0.075 ether);
        assertEq(m.operationsBudget(), 0.075 ether);
        solvent();
    }

    function testRevertFalsePartialAndInexactTransfersAreIsolatedThenClaimable() public {
        for (uint256 fault = 1; fault <= 4; ++fault) {
            uint256 snap = vm.snapshotState();
            start();
            imd.setFault(fault);
            uint256 before = imd.balanceOf(A);
            bid(B);
            assertEq(imd.balanceOf(A), before);
            assertEq(m.outgoingCredit(A), 0.8 ether);
            assertEq(m.totalOutgoingCredits(), 0.8 ether);
            assertEq(m.totalImdPaid(), 0);
            solvent();
            if (fault == 1) {
                vm.expectRevert(bytes("LOCAL outgoing blocked"));
            } else if (fault == 2) {
                vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(imd)));
            } else {
                vm.expectRevert(FinancierMining.InexactTransfer.selector);
            }
            vm.prank(A); // claim failures preserve the legitimate fallback
            m.claimImd();
            assertEq(m.outgoingCredit(A), 0.8 ether);
            imd.setFault(0);
            vm.prank(A);
            assertEq(m.claimImd(), 0.8 ether);
            vm.prank(A);
            assertEq(m.claimImd(), 0);
            solvent();
            vm.revertToState(snap);
        }
    }

    function testGasExhaustingOutgoingCallCannotHoldSlotHostage() public {
        start();
        imd.setFault(6);
        bid(B);
        assertEq(m.iFinancier(), B);
        assertEq(m.outgoingCredit(A), 0.8 ether);
        solvent();
    }

    function testFallbackCreditSurvivesLaterAutomaticPaymentAndLowGasRevertsAtomically() public {
        start();
        imd.setFault(1);
        bid(B);
        imd.setFault(0);
        vm.warp(block.timestamp + 1 hours);
        bid(A);
        vm.warp(block.timestamp + 1 hours);
        uint256 e = m.epoch();
        uint256 before = imd.balanceOf(A);
        vm.prank(B);
        (bool ok, bytes memory reason) =
            address(m).call{gas: 200_000}(abi.encodeCall(m.bid, (e, 1 ether, block.timestamp)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Mining.InsufficientPayoutGas.selector));
        assertEq(m.epoch(), e);
        assertEq(imd.balanceOf(A), before);
        assertEq(m.outgoingCredit(A), 0.8 ether);
        bid(B);
        assertEq(imd.balanceOf(A) - before, 0.8 ether);
        assertEq(m.outgoingCredit(A), 0.8 ether);
        vm.prank(A);
        assertEq(m.claimImd(), 0.8 ether);
        solvent();
    }

    function testLargeRevertDataCannotExhaustParentOrPersistPartialPayment() public {
        start();
        imd.setFault(7);
        bid(B);
        assertEq(m.iFinancier(), B);
        assertEq(m.outgoingCredit(A), 0.8 ether);
        solvent();
    }

    function testNoReturnExactTransferIsSuccessfulNotFallback() public {
        start();
        imd.setFault(5);
        bid(B);
        assertEq(m.outgoingCredit(A), 0);
        assertEq(m.totalImdPaid(), 0.8 ether);
        solvent();
    }

    function testReentrancyCannotCollectTwiceOrTakeOver() public {
        start();
        imd.setReentry(address(m), abi.encodeCall(m.claimImd, ()));
        bid(B);
        assertTrue(imd.attempted());
        assertFalse(imd.reentrySucceeded());
        assertEq(m.epoch(), 2);
        solvent();
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        m.payOutgoingExact(A, 1);
    }

    function testSelfBidSpendsOnlyNetWaterfallButDoesNotInflateEmissions() public {
        start();
        uint256 before = imd.balanceOf(A);
        uint256 earned = m.claimableFincr(A);
        bid(A);
        assertEq(before - imd.balanceOf(A), 0.2 ether);
        assertEq(m.claimableFincr(A), earned);
        solvent();
    }

    function testFuzzRoundingUsesExistingEntitlement(uint96 raw) public {
        uint256 price = bound(raw, 1, 100 ether);
        Mining tiny = make(price, price);
        f.transfer(address(tiny), 4e26);
        tiny.arm();
        imd.mint(A, price);
        imd.mint(B, price);
        vm.prank(A);
        imd.approve(address(tiny), price);
        vm.prank(A);
        tiny.bid(0, price, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(B);
        imd.approve(address(tiny), price);
        uint256 before = imd.balanceOf(A);
        vm.prank(B);
        tiny.bid(1, price, block.timestamp);
        uint256 outgoing = price - price * 500 / 10000 - price * 750 / 10000 - price * 375 / 10000 - price * 375 / 10000;
        assertEq(imd.balanceOf(A) - before, outgoing);
        assertEq(tiny.outgoingCredit(A), 0);
        assertEq(imd.balanceOf(address(tiny)), tiny.imdLiability());
    }

    function testZeroTerminalBidAndFinalFincrRemainIndependent() public {
        Mining zero = make(1 ether, 0);
        f.transfer(address(zero), 4e26);
        zero.arm();
        vm.prank(A);
        imd.approve(address(zero), 1 ether);
        vm.prank(A);
        zero.bid(0, 1 ether, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(B);
        zero.bid(1, 0, block.timestamp);
        assertEq(zero.totalImdPaid(), 0);
        assertEq(zero.outgoingCredit(A), 0);
        vm.warp(block.timestamp + 366 days);
        vm.prank(A);
        zero.claimFincr();
        vm.prank(B);
        zero.claimFincr();
        assertEq(zero.totalFincrPaid(), 3.2e26);
    }

    function testIncomingPaymentFailureRollsBackWholeTakeover() public {
        start();
        uint256 epoch = m.epoch();
        vm.prank(B);
        imd.approve(address(m), 0);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(m), 0, 1 ether)
        );
        vm.prank(B);
        m.bid(epoch, 1 ether, block.timestamp);
        assertEq(m.epoch(), epoch);
        assertEq(m.iFinancier(), A);
        assertEq(m.totalImdPaid(), 0);
        solvent();
    }

    function testComparableWarmExecutionGasAutoVersusPull() public {
        FinancierMining pull =
            new FinancierMining(address(f), address(imd), 1e27, 1 ether, 1 ether, address(this), address(105));
        f.transfer(address(pull), 4e26);
        pull.arm();
        vm.prank(A);
        imd.approve(address(pull), 1 ether);
        vm.prank(B);
        imd.approve(address(pull), 1 ether);
        vm.prank(A);
        pull.bid(0, 1 ether, block.timestamp);
        bid(A);
        vm.warp(block.timestamp + 1 hours);
        uint256 g = gasleft();
        vm.prank(B);
        pull.bid(1, 1 ether, block.timestamp);
        uint256 pullBid = g - gasleft();
        g = gasleft();
        vm.prank(A);
        pull.claimImd();
        uint256 pullClaim = g - gasleft();
        g = gasleft();
        bid(B);
        uint256 automatic = g - gasleft();
        emit log_named_uint("Warm pull takeover execution", pullBid);
        emit log_named_uint("Warm separate claim execution", pullClaim);
        emit log_named_uint("Warm automatic takeover execution", automatic);
    }
}
