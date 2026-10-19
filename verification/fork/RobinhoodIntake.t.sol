// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {IIMDIntake} from "../../src/interfaces/IIMDIntake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IIntakeViews {
    // HMM Intake v2 source; exact selector/arguments also observed in actual fork revert.
    error PriceNotMet(uint256 price, uint256 amount);
    function nonce() external view returns (uint256);
    function priceOf(bytes32, address) external view returns (uint256);
    function payTo() external view returns (address);
    function requests(bytes32) external view returns (address, address, bytes4, bool);
    function failureSelectorOf(bytes32) external view returns (bytes4);
}

/// Calls deployed Intake bytecode, solely in Forge's local EVM fork. No live job is created.
contract RobinhoodIntakeForkTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 constant JOB = "job.open@job-1";

    function setUp() public view {
        require(block.chainid == 4663, "wrong chain");
        require(
            INTAKE.codehash == 0xd96f270d009efd0fda0a2da91bb7f835a2686182e3abccd18966984134d3b5e8,
            "Intake runtime drift"
        );
        require(IMD.codehash == 0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2, "IMD runtime drift");
    }

    bytes4 constant CALLBACK = bytes4(keccak256("result(bytes32)"));
    bytes4 constant FAILURE = bytes4(keccak256("failure(bytes32,uint8,bytes32,uint16,uint16,bytes)"));

    // Both tests use identical method/action/body/callback/asset; only offered amount varies.
    function request(uint256 amount) internal returns (bytes32) {
        return IIMDIntake(INTAKE)
            .requestWithFailure(
                JOB,
                bytes("{\"objective\":\"LOCAL FORK ONLY; NEVER SUBMIT\"}"),
                IIMDIntake.Callback(address(this), CALLBACK),
                FAILURE,
                IMD,
                amount
            );
    }

    function assertNoRequest(bytes32 id) internal view {
        (address payer, address target, bytes4 selector, bool completed) = IIntakeViews(INTAKE).requests(id);
        assertEq(payer, address(0));
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
        assertEq(IIntakeViews(INTAKE).failureSelectorOf(id), bytes4(0));
    }

    function assertRequest(bytes32 id) internal view {
        (address payer, address target, bytes4 selector, bool completed) = IIntakeViews(INTAKE).requests(id);
        assertEq(payer, address(this));
        assertEq(target, address(this));
        assertEq(selector, CALLBACK);
        assertFalse(completed);
        assertEq(IIntakeViews(INTAKE).failureSelectorOf(id), FAILURE);
    }

    function testActualPricePaymentAndRecordedRequest() public {
        uint256 price = IIntakeViews(INTAKE).priceOf(JOB, IMD);
        assertEq(price, 0.5 ether);
        deal(IMD, address(this), price);
        IERC20(IMD).approve(INTAKE, price);
        address payTo = IIntakeViews(INTAKE).payTo();
        uint256 before = IERC20(IMD).balanceOf(payTo);
        bytes32 id = request(price);
        assertEq(IERC20(IMD).balanceOf(payTo) - before, price);
        assertEq(IERC20(IMD).balanceOf(address(this)), 0);
        assertRequest(id);
    }

    function testActualShortPaymentRevertsWithoutDebit() public {
        uint256 price = IIntakeViews(INTAKE).priceOf(JOB, IMD);
        assertGt(price, 0);
        deal(IMD, address(this), price);
        IERC20(IMD).approve(INTAKE, price);
        uint256 nonceBefore = IIntakeViews(INTAKE).nonce();
        bytes32 expectedId = keccak256(abi.encode(block.chainid, INTAKE, nonceBefore + 1));
        address payTo = IIntakeViews(INTAKE).payTo();
        uint256 payeeBefore = IERC20(IMD).balanceOf(payTo);
        uint256 intakeBefore = IERC20(IMD).balanceOf(INTAKE);
        uint256 allowanceBefore = IERC20(IMD).allowance(address(this), INTAKE);
        assertNoRequest(expectedId);

        vm.expectRevert(abi.encodeWithSelector(IIntakeViews.PriceNotMet.selector, price, price - 1));
        request(price - 1);
        assertEq(IERC20(IMD).balanceOf(address(this)), price);
        assertEq(IERC20(IMD).balanceOf(payTo), payeeBefore);
        assertEq(IERC20(IMD).balanceOf(INTAKE), intakeBefore);
        assertEq(IERC20(IMD).allowance(address(this), INTAKE), allowanceBefore);
        assertEq(IIntakeViews(INTAKE).nonce(), nonceBefore);
        assertNoRequest(expectedId);

        // Positive control without changing approvals/callback/body or resetting state.
        bytes32 id = request(price);
        assertEq(id, expectedId);
        assertEq(IIntakeViews(INTAKE).nonce(), nonceBefore + 1);
        assertEq(IERC20(IMD).balanceOf(payTo) - payeeBefore, price);
        assertEq(IERC20(IMD).balanceOf(address(this)), 0);
        assertRequest(id);
    }
}
