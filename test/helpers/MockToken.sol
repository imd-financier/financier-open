// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test only. Includes transfer taxes, lies, missing/false return values and callbacks.
contract MockToken is ERC20 {
    uint256 public initialSupply;
    uint256 public mode;
    bool public blocked;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSuccess;
    bytes public callbackResult;
    bool private calling;

    constructor() ERC20("Test token", "TEST") {}

    function mint(address to, uint256 amount) external {
        initialSupply += amount;
        _mint(to, amount);
    }

    function confiscate(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setMode(uint256 value) external {
        mode = value;
    }

    function setBlocked(bool value) external {
        blocked = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(!blocked, "blocked transfer");
        if (mode == 4) return false;
        if (mode == 7) return true;
        if (mode == 2 && amount > 0) {
            _transfer(from, to, amount - 1);
            _burn(from, 1);
        } else {
            _transfer(from, to, amount);
        }
        if (mode == 3) _burn(from, 1);
        if (callbackTarget != address(0) && !calling) {
            calling = true;
            callbackAttempted = true;
            (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
            calling = false;
        }
        if (mode == 5) assembly ("memory-safe") { return(0, 0) }
        return true;
    }
}
