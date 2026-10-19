// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Published IMD Intake v2 request ABI, https://imd.fun/docs/ (2026-10-15).
/// @dev Actual Robinhood runtime/payment path rehearsed on a local fork in Task #5.
/// Callback/result authority and bounded FINANCIER spending policy remain production gates.
/// No FINANCIER work-budget spender or allowance is enabled by this interface.
interface IIMDIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}
