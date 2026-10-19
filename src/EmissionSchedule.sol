// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Task #3 candidate, not approved production parameters. Elapsed whole seconds.
library EmissionSchedule {
    uint256 internal constant ERA = 14 days;
    uint256 internal constant LAUNCH_END = 42 days;
    uint256 internal constant END = 365 days;

    /// @dev Exactly TwoPhaseCurve(14 days, 3 eras, 6000 bps, 365 days).
    /// Single cumulative floor across launch eras; never floor each tenure/era separately.
    function gross(uint256 reserve, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= END) return reserve;
        uint256 fast = Math.mulDiv(reserve, 3, 5);
        if (elapsed >= LAUNCH_END) {
            return fast + Math.mulDiv(reserve - fast, elapsed - LAUNCH_END, END - LAUNCH_END);
        }
        uint256 weightedSeconds;
        if (elapsed < ERA) weightedSeconds = elapsed * 4;
        else if (elapsed < 2 * ERA) weightedSeconds = 4 * ERA + 2 * (elapsed - ERA);
        else weightedSeconds = 6 * ERA + elapsed - 2 * ERA;
        return Math.mulDiv(fast, weightedSeconds, 7 * ERA);
    }

    function split(uint256 reserve, uint256 elapsed) internal pure returns (uint256 f, uint256 a) {
        uint256 e = gross(reserve, elapsed);
        f = Math.mulDiv(e, 4, 5);
        a = e - f;
    }
}
