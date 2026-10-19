// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev ABI subset checked against Robinhood explorer-verified PoolManager source.
interface IV4Market {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata, SwapParams calldata, bytes calldata) external returns (int256);
    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (int256, int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice REQUIRED independent reference adapter, not an assertion that one exists.
/// A production adapter must not derive its fair price from this manipulable pool's spot.
