// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RestrictedMarketReserveReceiver as Receiver} from "./RestrictedMarketReserveReceiver.sol";
import {FinancierMiningWithMarket as Mining} from "./FinancierMiningWithMarket.sol";
import {FINCR} from "./FINCR.sol";

interface IOfficialPoolFees {
    function claimFees(uint64 number) external returns (uint256, uint256);
}

/// @notice Immutable requester-fee destination: all IMD funds work, all FINCR burns.
/// @dev Candidate policy for founder review, not deployment permission. No owner, setters,
/// arbitrary calls, rescue or requester handoff. Other assets are inaccessible. Donations
/// follow the same rules; routed balances alone are NOT proof of fees earned.
contract FinancierFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public constant FACTORY = 0x9C9D2FCB75c2C132C0AC0C42DF3819A42347265e;
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 public constant FACTORY_HASH = 0x46c834a83deedf1fe46fe2161fcf49fe5b93af45e08bb7dbe0d7ecc31ee07a4b;
    Receiver public immutable receiver;
    bytes32 public immutable receiverHash;
    uint256 public totalImdRouted;
    uint256 public totalFincrBurned;
    error Unauthenticated();
    error Inexact();
    event WorkFeesRouted(address indexed miner, uint256 amount);
    event FeeFincrBurned(address indexed token, uint256 amount);

    constructor(Receiver receiver_) {
        if (block.chainid != 4663 || FACTORY.codehash != FACTORY_HASH || address(receiver_).code.length == 0) {
            revert Unauthenticated();
        }
        // The exact receiver source/configuration must be reviewed before deployment.
        (Receiver.Pins memory p, Receiver.Settings memory s) = receiver_.configuration();
        if (p.factory != FACTORY || p.factoryHash != FACTORY_HASH || s.imd != IMD) revert Unauthenticated();
        receiver = receiver_;
        receiverHash = address(receiver_).codehash;
    }

    function _canonical() private view returns (address token, Mining miner) {
        if (
            block.chainid != 4663 || FACTORY.codehash != FACTORY_HASH || address(receiver).codehash != receiverHash
                || !receiver.bootstrapped()
        ) revert Unauthenticated();
        token = receiver.canonicalToken();
        miner = Mining(receiver.canonicalMiner());
        if (
            token.code.length == 0 || address(miner).code.length == 0 || address(miner.fincr()) != token
                || address(miner.imd()) != IMD || miner.initializer() != address(receiver)
        ) revert Unauthenticated();
    }

    /// @notice Collection uses only the receiver's authenticated canonical launch number.
    /// Fees are paid by the factory to its recorded recipients, never to the caller.
    function collect() external nonReentrant {
        _canonical();
        IOfficialPoolFees(FACTORY).claimFees(receiver.canonicalLaunchNumber());
    }

    function routeImd() external nonReentrant {
        (, Mining miner) = _canonical();
        IERC20 imd = IERC20(IMD);
        uint256 amount = imd.balanceOf(address(this));
        if (amount == 0) return;
        imd.forceApprove(address(miner), amount);
        miner.fundWork(amount);
        imd.forceApprove(address(miner), 0);
        if (imd.balanceOf(address(this)) != 0 || imd.allowance(address(this), address(miner)) != 0) revert Inexact();
        totalImdRouted += amount;
        emit WorkFeesRouted(address(miner), amount);
    }

    function burnFincr() external nonReentrant {
        (address token,) = _canonical();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 beforeSupply = IERC20(token).totalSupply();
        FINCR(token).burn(amount);
        if (IERC20(token).balanceOf(address(this)) != 0 || IERC20(token).totalSupply() != beforeSupply - amount) {
            revert Inexact();
        }
        totalFincrBurned += amount;
        emit FeeFincrBurned(token, amount);
    }
}
