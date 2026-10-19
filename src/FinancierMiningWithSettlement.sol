// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FinancierMining} from "./FinancierMining.sol";
import {AttestedAgentRounds} from "./AttestedAgentRounds.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIMDIntake} from "./interfaces/IIMDIntake.sol";
import {IIMDIntakeViews} from "./interfaces/IIMDIntakeViews.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

/// @notice Integrated owner-authorized settlement candidate. No reject-all verifier dependency.
/// Twelve static app words fit the published custom-token <=16-word schema.
contract FinancierMiningWithSettlement is FinancierMining {
    using SafeERC20 for IERC20;
    AttestedAgentRounds public immutable agentRounds;
    address public constant WORK_INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address public constant WORK_ASSET = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 public constant INTAKE_CODEHASH = 0xd96f270d009efd0fda0a2da91bb7f835a2686182e3abccd18966984134d3b5e8;
    bytes32 public constant IMD_CODEHASH = 0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2;
    bytes32 public constant WORK_ACTION = "job.open@job-1";
    uint256 public constant WORK_FEE = 0.5 ether; // Candidate fixed service price, NOT a fee setter.

    struct WorkRequest {
        uint256 roundPlusOne;
        bytes32 bodyHash;
        uint256 requestedAt;
    }
    mapping(bytes32 => WorkRequest) public workRequests;
    // Global exact-body one-use intent, including paid requests never admitted by the backend.
    mapping(bytes32 => bool) public dispatchedBody;
    uint256 public totalWorkSpent;
    uint256 public constant AUTO_PAYOUT_GAS = 150_000;
    uint256 public constant PAYOUT_GAS_RESERVE = 50_000;
    error InsufficientPayoutGas();
    event OutgoingImdPaid(address indexed financier, uint256 amount);
    event OutgoingImdFallback(address indexed financier, uint256 amount, bytes32 failurePrefix);
    error UnsupportedWorkService();
    error WorkFeeChanged(uint256 observed);
    error InvalidWorkIntent();
    error InvalidWorkRequest();
    event WorkDispatched(
        bytes32 indexed requestId,
        uint256 indexed roundId,
        bytes32 indexed bodyHash,
        uint256 requestedAt,
        uint256 amount,
        address payer
    );

    constructor(
        address fincr_,
        address imd_,
        uint256 supply_,
        uint256 initialQuote_,
        uint256 floor_,
        address initializer_,
        address operationsRecipient_,
        address authority_,
        bytes32 policy_,
        uint256 roundSeconds_,
        uint256 graceSeconds_,
        uint256 identityMaxAge_
    ) FinancierMining(fincr_, imd_, supply_, initialQuote_, floor_, initializer_, operationsRecipient_) {
        agentRounds =
            new AttestedAgentRounds(address(this), authority_, policy_, roundSeconds_, graceSeconds_, identityMaxAge_);
    }

    function agentController() public view override returns (address) {
        return address(agentRounds);
    }

    function outgoingPaymentMode() external pure returns (bytes32) {
        return "automatic-fallback-v1";
    }

    function _afterTakeoverPayment(address previous, uint256 amount) internal virtual override {
        if (amount == 0) return;
        // Preserve enough gas to retain credit and complete takeover even if the child exhausts its cap.
        if (gasleft() < AUTO_PAYOUT_GAS + PAYOUT_GAS_RESERVE) revert InsufficientPayoutGas();
        bytes memory data = abi.encodeCall(this.payOutgoingExact, (previous, amount));
        uint256 cap = AUTO_PAYOUT_GAS;
        bool ok;
        bytes32 prefix;
        // Never copy unbounded revert data from a hostile token. Only a padded 32-byte prefix.
        assembly ("memory-safe") {
            ok := call(cap, address(), 0, add(data, 32), mload(data), 0, 0)
            let p := mload(0x40)
            mstore(p, 0)
            let n := returndatasize()
            if gt(n, 32) { n := 32 }
            returndatacopy(p, 0, n)
            prefix := mload(p)
        }
        if (ok) {
            emit OutgoingImdPaid(previous, amount);
        } else {
            emit OutgoingImdFallback(previous, amount, prefix);
        }
    }

    /// @notice Self-call isolation only; not an arbitrary transfer/withdrawal entry point.
    /// Bid's shared reentrancy guard remains entered. A revert undoes ALL child token/accounting effects.
    function payOutgoingExact(address beneficiary, uint256 amount) external {
        if (msg.sender != address(this)) revert Unauthorized();
        outgoingCredit[beneficiary] -= amount;
        totalOutgoingCredits -= amount;
        totalImdPaid += amount;
        _sendExact(imd, beneficiary, amount);
    }

    /// @notice Buy exactly one prospectively scoped job using ONLY the accumulated work bucket.
    /// No callback, automatic retry, arbitrary action/asset/target or permission on any other bucket.
    /// Backend refusal/timeout remains a paid, consumed intent; admission is polled separately.
    function dispatchWork(uint256 id, bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        if (msg.sender != agentRounds.settlementAuthority()) revert Unauthorized();
        IAgentWorkVerifier.Context memory c = agentRounds.context(id);
        if (block.timestamp < c.start || block.timestamp >= c.end) revert InvalidWorkIntent();
        bytes32 bodyHash = keccak256(body);
        if (
            body.length == 0 || body.length > 16_384 || !agentRounds.permittedRequestBody(id, bodyHash)
                || dispatchedBody[bodyHash]
        ) revert InvalidWorkIntent();
        if (
            block.chainid != 4663 || address(imd) != WORK_ASSET || WORK_INTAKE.codehash != INTAKE_CODEHASH
                || WORK_ASSET.codehash != IMD_CODEHASH
        ) revert UnsupportedWorkService();
        IIMDIntakeViews intake = IIMDIntakeViews(WORK_INTAKE);
        uint256 price = intake.priceOf(WORK_ACTION, WORK_ASSET);
        if (price != WORK_FEE) revert WorkFeeChanged(price);
        if (workBudget < WORK_FEE || imd.balanceOf(address(this)) < imdLiability()) revert Unfunded();

        dispatchedBody[bodyHash] = true;
        workBudget -= WORK_FEE;
        totalImdPaid += WORK_FEE;
        totalWorkSpent += WORK_FEE;
        requestId = _purchaseWork(body, intake);
        if (requestId == 0 || workRequests[requestId].roundPlusOne != 0) revert InvalidWorkRequest();
        workRequests[requestId] = WorkRequest(id + 1, bodyHash, block.timestamp);
        emit WorkDispatched(requestId, id, bodyHash, block.timestamp, WORK_FEE, address(this));
    }

    function _purchaseWork(bytes calldata body, IIMDIntakeViews intake) internal virtual returns (bytes32 id) {
        address payee = intake.payTo();
        uint256 vaultBefore = imd.balanceOf(address(this));
        uint256 payeeBefore = imd.balanceOf(payee);
        imd.forceApprove(WORK_INTAKE, WORK_FEE);
        id = IIMDIntake(WORK_INTAKE)
            .request(WORK_ACTION, body, IIMDIntake.Callback(address(0), bytes4(0)), WORK_ASSET, WORK_FEE);
        imd.forceApprove(WORK_INTAKE, 0);
        uint256 vaultAfter = imd.balanceOf(address(this));
        uint256 payeeAfter = imd.balanceOf(payee);
        if (
            vaultAfter > vaultBefore || vaultBefore - vaultAfter != WORK_FEE || payeeAfter < payeeBefore
                || payeeAfter - payeeBefore != WORK_FEE || imd.allowance(address(this), WORK_INTAKE) != 0
        ) revert InexactTransfer();
        (address payer, address target, bytes4 selector, bool completed) = intake.requests(id);
        if (payer != address(this) || target != address(0) || selector != 0 || completed) revert InvalidWorkRequest();
    }
}
