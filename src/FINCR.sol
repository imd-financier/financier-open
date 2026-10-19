// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Launch candidate, NOT a deployed/approved production token or cap.
/// @dev Single mint to constructor caller (launch factory in the proposed route), true voluntary burn.
/// No owner, additional mint, transfer tax, denylist, pause or upgrade.
contract FINCR is ERC20 {
    uint256 public immutable initialSupply;

    constructor(uint256 supply) ERC20("FINANCIER", "FINCR") {
        require(supply != 0 && supply % 100 == 0, "invalid supply");
        initialSupply = supply;
        _mint(msg.sender, supply);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
