// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract SecurityReviewTest is Test {
    function testRejectSelfInitializerThatCanNeverArm() public {
        MockToken f = new MockToken();
        MockToken i = new MockToken();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(FinancierMining.InvalidConfiguration.selector);
        new FinancierMining(address(f), address(i), 1e27, 1 ether, 1 ether, predicted, address(123));
    }
}
