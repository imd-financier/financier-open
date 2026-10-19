// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIMDIntake} from "../../src/interfaces/IIMDIntake.sol";
import {IIntakeViews} from "./RobinhoodIntake.t.sol";

/// Actual runtime/storage, local EOA impersonation/injected test IMD only. No service admission.
contract ResearchUtilityForkTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant PAYER = address(0xD00D);

    function testDirectUserPaysExactBoundedFeeWithNoCallbackOrVault() public {
        assertEq(block.chainid, 4663);
        assertEq(IMD.codehash, 0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2);
        assertEq(INTAKE.codehash, 0xd96f270d009efd0fda0a2da91bb7f835a2686182e3abccd18966984134d3b5e8);
        assertEq(IIntakeViews(INTAKE).priceOf("job.open@job-1", IMD), 0.5 ether);
        address payee = IIntakeViews(INTAKE).payTo();
        uint256 before = IERC20(IMD).balanceOf(payee);
        deal(IMD, PAYER, 1 ether);
        vm.startPrank(PAYER);
        IERC20(IMD).approve(INTAKE, 0.5 ether);
        bytes32 id = IIMDIntake(INTAKE)
            .request(
                "job.open@job-1",
                bytes(
                    '{"objective":"LOCAL FORK ONLY: research official IMD Intake payment and admission. NEVER SUBMIT.","skill":"research-report","github":false}'
                ),
                IIMDIntake.Callback(address(0), bytes4(0)),
                IMD,
                0.5 ether
            );
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(PAYER), 0.5 ether);
        assertEq(IERC20(IMD).balanceOf(payee) - before, 0.5 ether);
        assertEq(IERC20(IMD).allowance(PAYER, INTAKE), 0);
        (address payer, address target, bytes4 selector, bool completed) = IIntakeViews(INTAKE).requests(id);
        assertEq(payer, PAYER);
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
    }
}
