// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FinancierMiningWithMarket} from "./FinancierMiningWithMarket.sol";
import {RobinhoodJobController} from "./RobinhoodJobController.sol";
import {IIMDIntake} from "./interfaces/IIMDIntake.sol";
import {IIMDIntakeViews} from "./interfaces/IIMDIntakeViews.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Post-launch founder-funded variant of the existing vetted miner. No forwarder or rescue.
/// @dev Founder chooses the canonical instance by deploying with the verified FINCR address.
/// This reviewed runtime hash includes FINCR's immutable initialSupply = 1 billion, not a template.
contract FounderFundedMining is FinancierMiningWithMarket {
    using SafeERC20 for IERC20;
    bytes32 public constant FINCR_HASH = 0x946270e19519507b25f0e64ba542b050d325476e1a397aadf1f64ea23d16064c;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant RESERVE = 400_000_000 ether;
    RobinhoodJobController public immutable jobs;

    struct Completion {
        bool recorded;
        uint8 status;
        bytes32 resultHash;
        bytes32 uriHash;
    }
    mapping(bytes32 => Completion) public completions;
    error InvalidCanonicalConfiguration();
    error InvalidCompletion();
    event WorkCompleted(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri);

    constructor(Config memory c) FinancierMiningWithMarket(_nativeConfig(c)) {
        if (
            block.chainid != 4663 || c.initializer != msg.sender || c.initializer == c.operations
                || c.fincr.codehash != FINCR_HASH || c.supply != SUPPLY || c.quote != 10 ether
                || c.floor != 0.5 ether || c.maxMarketBatch != 0.1 ether
        ) revert InvalidCanonicalConfiguration();
        jobs = new RobinhoodJobController(address(this));
        if (address(jobs) != agentRounds.settlementAuthority()) revert InvalidCanonicalConfiguration();
    }

    // Existing miner creates rounds at nonce 1 and market at nonce 2. The only authority
    // is this exact non-upgradeable dispatch controller at nonce 3, with NO finalize entry point.
    function _nativeConfig(Config memory c) private view returns (Config memory) {
        if (c.authority != address(0)) revert InvalidCanonicalConfiguration();
        c.authority = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"03")))));
        return c;
    }

    /// Explicit second transaction after normal ERC20 transfer. Donations never activate anything.
    /// Excess is locked surplus, not extra emissions; equality would permit a one-wei donation DoS.
    function arm() external override nonReentrant {
        if (msg.sender != initializer) revert Unauthorized();
        if (armed) revert AlreadyArmed();
        if (block.chainid != 4663 || address(fincr).codehash != FINCR_HASH) revert InvalidCanonicalConfiguration();
        if (fincr.balanceOf(address(this)) < RESERVE) revert Unfunded();
        jobs.prepareRound(0);
        armed = true;
        auctionStart = block.timestamp;
        emit AuctionOpened(auctionStart, initialQuote, terminalFloor);
        emit Armed(msg.sender, RESERVE);
    }

    function _purchaseWork(bytes calldata body, IIMDIntakeViews intake) internal override returns (bytes32 id) {
        address payee = intake.payTo();
        uint256 beforeVault = imd.balanceOf(address(this));
        uint256 beforePayee = imd.balanceOf(payee);
        imd.forceApprove(WORK_INTAKE, WORK_FEE);
        id = IIMDIntake(WORK_INTAKE).requestWithFailure(
            WORK_ACTION, body, IIMDIntake.Callback(address(this), this.onResult.selector), this.onFailure.selector,
            WORK_ASSET, WORK_FEE
        );
        imd.forceApprove(WORK_INTAKE, 0);
        if (imd.balanceOf(address(this)) != beforeVault - WORK_FEE || imd.balanceOf(payee) != beforePayee + WORK_FEE
            || imd.allowance(address(this), WORK_INTAKE) != 0) revert InexactTransfer();
        (address payer, address target, bytes4 selector, bool complete) = intake.requests(id);
        if (payer != address(this) || target != address(this) || selector != this.onResult.selector || complete) {
            revert InvalidWorkRequest();
        }
    }

    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external {
        if (resultHash == 0 || bytes(uri).length == 0 || bytes(uri).length > 2048) revert InvalidCompletion();
        _record(requestId, 0, resultHash, uri);
    }

    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        if (status != 1 && status != 2) revert InvalidCompletion();
        _record(requestId, status, reason, "");
    }

    function _record(bytes32 id, uint8 status, bytes32 hash, string memory uri) private {
        if (block.chainid != 4663 || msg.sender != WORK_INTAKE || WORK_INTAKE.codehash != INTAKE_CODEHASH
            || workRequests[id].roundPlusOne == 0 || completions[id].recorded) revert InvalidCompletion();
        (address payer, address target, bytes4 selector, bool complete) = IIMDIntakeViews(WORK_INTAKE).requests(id);
        if (payer != address(this) || target != address(this) || selector != this.onResult.selector || !complete) {
            revert InvalidCompletion();
        }
        completions[id] = Completion(true, status, hash, keccak256(bytes(uri)));
        emit WorkCompleted(id, status, hash, uri);
        // Never parse caller-supplied membership or finalize a round from mere completion.
    }
}
