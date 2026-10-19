// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Read ABI exercised against the pinned Robinhood Intake v2 runtime.
interface IIMDIntakeViews {
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function payTo() external view returns (address);
    function requests(bytes32 id) external view returns (address payer, address target, bytes4 selector, bool completed);
}
