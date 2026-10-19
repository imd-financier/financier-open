// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EmissionSchedule} from "./EmissionSchedule.sol";

interface IInitialSupply {
    function initialSupply() external view returns (uint256);
}

/// @notice Non-upgradeable prototype: one Dutch mining slot and its finite funded vault.
/// @dev No verifier, swaps, LP execution, arbitrary calls, token rescue or budget reallocation.
/// Work/buyback/LP IMD stay isolated. Agent payout is disabled in this base; the derived variant binds immutable rounds.
contract FinancierMining is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant AUCTION_DURATION = 1 hours;
    uint256 public constant MIN_RESET_PRICE = 1e14; // Legacy ABI getter only; never bounds the fixed reset.
    uint256 public constant MAX_RESET_PRICE = type(uint192).max;
    uint256 public constant EMISSION_END = 365 days;

    IERC20 public immutable fincr;
    IERC20 public immutable imd;
    uint256 public immutable initialSupply;
    uint256 public immutable miningReserve;
    uint256 public immutable initialQuote;
    uint256 public immutable terminalFloor;
    address public immutable initializer;
    address public immutable operationsRecipient;

    bool public armed;
    address public iFinancier;
    uint256 public epoch;
    uint256 public genesis;
    uint256 public auctionStart; // Auction clock begins at authenticated arm; emissions still begin at first bid.
    uint256 public tenureStart;
    uint256 public tenureStartFinancierCumulative;
    uint256 public resetPrice;
    uint256 public financierCursor;
    uint256 public totalFincrPaid;
    uint256 public totalAgentPaid;
    uint256 public totalFincrCredits;
    uint256 public totalBidVolume;
    uint256 public totalImdPaid;
    uint256 public totalOutgoingCredits;
    uint256 public workBudget;
    uint256 public buybackBudget;
    uint256 public liquidityBudget;
    uint256 public operationsBudget;
    mapping(address => uint256) public fincrCredit;
    mapping(address => uint256) public outgoingCredit;

    error InvalidConfiguration();
    error Unauthorized();
    error AlreadyArmed();
    error NotArmed();
    error Unfunded();
    error SupplyMismatch();
    error StaleEpoch();
    error Expired();
    error PriceExceeded();
    error InexactTransfer();
    error InvalidInterval();

    event Armed(address indexed initializer, uint256 reserve);
    event AuctionOpened(uint256 timestamp, uint256 openingQuote, uint256 floor);
    event MiningStarted(uint256 genesis, address indexed financier);
    event Takeover(
        uint256 indexed epoch,
        address indexed outgoing,
        address indexed incoming,
        uint256 paid,
        uint256 nextResetPrice,
        uint256 timestamp
    );
    event FinancierAccrued(address indexed financier, uint256 amount, uint256 cumulative);
    event BidAllocated(
        uint256 indexed epoch, uint256 outgoing, uint256 work, uint256 buyback, uint256 liquidity, uint256 operations
    );
    event FincrClaimed(address indexed financier, uint256 amount);
    event ImdClaimed(address indexed financier, uint256 amount);
    event OperationsClaimed(address indexed recipient, uint256 amount);

    constructor(
        address fincr_,
        address imd_,
        uint256 supply_,
        uint256 initialQuote_,
        uint256 floor_,
        address initializer_,
        address operationsRecipient_
    ) {
        if (
            fincr_ == imd_ || fincr_.code.length == 0 || imd_.code.length == 0 || supply_ == 0 || supply_ % 100 != 0
                || initializer_ == address(0) || initializer_ == address(this) || operationsRecipient_ == address(0)
                || operationsRecipient_ == address(this) || initialQuote_ == 0 || initialQuote_ < floor_
                || initialQuote_ > MAX_RESET_PRICE
        ) revert InvalidConfiguration();
        fincr = IERC20(fincr_);
        imd = IERC20(imd_);
        initialSupply = supply_;
        miningReserve = Math.mulDiv(supply_, 2, 5);
        initialQuote = initialQuote_;
        terminalFloor = floor_;
        initializer = initializer_;
        operationsRecipient = operationsRecipient_;
    }

    /// @notice One-shot authenticated readiness; does not start the emission clock.
    /// @dev Direct funding/donations confer no control. No approved spender is installed.
    function arm() external virtual nonReentrant {
        if (msg.sender != initializer) revert Unauthorized();
        if (armed) revert AlreadyArmed();
        if (IInitialSupply(address(fincr)).initialSupply() != initialSupply || fincr.totalSupply() > initialSupply) {
            revert SupplyMismatch();
        }
        if (fincr.balanceOf(address(this)) < miningReserve) revert Unfunded();
        armed = true;
        auctionStart = block.timestamp;
        emit AuctionOpened(auctionStart, initialQuote, terminalFloor);
        emit Armed(msg.sender, miningReserve);
    }

    /// @notice No pre-arm auction. Arming starts genesis price decay, never mining emissions.
    /// The immutable terminal floor applies to genesis and every subsequent epoch.
    function currentPrice() public view returns (uint256) {
        if (!armed) return initialQuote;
        uint256 start = epoch == 0 ? auctionStart : tenureStart;
        uint256 opening = epoch == 0 ? initialQuote : resetPrice;
        uint256 sinceStart = block.timestamp - start;
        if (sinceStart >= AUCTION_DURATION) return terminalFloor;
        return opening - Math.mulDiv(opening - terminalFloor, sinceStart, AUCTION_DURATION);
    }

    /// @notice Pays exactly the live quote. Caller is both payer and new financier; no nominees.
    function bid(uint256 expectedEpoch, uint256 maxPrice, uint256 deadline) external nonReentrant {
        if (!armed) revert NotArmed();
        if (expectedEpoch != epoch) revert StaleEpoch();
        if (block.timestamp > deadline) revert Expired();
        uint256 price = currentPrice();
        if (price > maxPrice) revert PriceExceeded();
        address previous = iFinancier;
        if (epoch == 0) {
            if (fincr.balanceOf(address(this)) < miningReserve) revert Unfunded();
            genesis = block.timestamp;
            emit MiningStarted(genesis, msg.sender);
        } else {
            _checkpoint();
        }
        iFinancier = msg.sender;
        tenureStart = block.timestamp;
        tenureStartFinancierCumulative = financierCursor;
        ++epoch;
        resetPrice = initialQuote; // Every takeover restarts the same immutable opening quote.
        uint256 outgoing = _allocate(price, previous);
        // Effects roll back on any transfer failure or non-exact receipt/debit.
        if (price != 0) _receiveExact(imd, msg.sender, price);
        _afterTakeoverPayment(previous, outgoing);
        emit Takeover(epoch, previous, msg.sender, price, resetPrice, block.timestamp);
    }

    /// @dev Legacy base retains pull-only behavior; integrated candidate overrides this hook.
    function _afterTakeoverPayment(address, uint256) internal virtual {}

    function _allocate(uint256 price, address previous) private returns (uint256 outgoing) {
        uint256 work = Math.mulDiv(price, 500, 10000);
        uint256 buyback = Math.mulDiv(price, 750, 10000);
        uint256 liquidity = Math.mulDiv(price, 375, 10000);
        uint256 operations = Math.mulDiv(price, 375, 10000);
        // Proposed dust rule matches the Python model: <4 base units extra to outgoing.
        outgoing = price - work - buyback - liquidity - operations;
        if (previous == address(0)) {
            // Prototype genesis policy only: otherwise unowed outgoing part goes to work.
            work += outgoing;
            outgoing = 0;
        } else {
            outgoingCredit[previous] += outgoing;
            totalOutgoingCredits += outgoing;
        }
        workBudget += work;
        buybackBudget += buyback;
        liquidityBudget += liquidity;
        operationsBudget += operations;
        totalBidVolume += price;
        emit BidAllocated(epoch, outgoing, work, buyback, liquidity, operations);
    }

    function elapsed() public view returns (uint256) {
        return epoch == 0 ? 0 : block.timestamp - genesis;
    }

    /// @notice Candidate curve at any elapsed time, independent of live state.
    function cumulativeAt(uint256 secondsAfterGenesis) public view returns (uint256 gross, uint256 f, uint256 a) {
        (f, a) = EmissionSchedule.split(miningReserve, secondsAfterGenesis);
        gross = f + a;
    }

    /// @notice Agent stream interval interface, not an authorization to distribute or reuse it.
    function agentAllocation(uint256 fromElapsed, uint256 toElapsed) external view returns (uint256) {
        if (toElapsed < fromElapsed) revert InvalidInterval();
        (, uint256 a0) = EmissionSchedule.split(miningReserve, fromElapsed);
        (, uint256 a1) = EmissionSchedule.split(miningReserve, toElapsed);
        return a1 - a0;
    }

    function agentReserved() public view returns (uint256) {
        (, uint256 a) = EmissionSchedule.split(miningReserve, elapsed());
        return a;
    }

    function currentTenureEarned() external view returns (uint256) {
        (uint256 f,) = EmissionSchedule.split(miningReserve, elapsed());
        return f - tenureStartFinancierCumulative;
    }

    function claimableFincr(address financier) public view returns (uint256 amount) {
        amount = fincrCredit[financier];
        if (financier == iFinancier && epoch != 0) {
            (uint256 f,) = EmissionSchedule.split(miningReserve, elapsed());
            amount += f - financierCursor;
        }
    }

    function _checkpoint() private {
        if (epoch == 0) return;
        (uint256 f,) = EmissionSchedule.split(miningReserve, elapsed());
        uint256 accrued = f - financierCursor;
        financierCursor = f;
        fincrCredit[iFinancier] += accrued;
        totalFincrCredits += accrued;
        if (accrued != 0) emit FinancierAccrued(iFinancier, accrued, f);
    }

    /// @notice Active, former and final financiers can claim; no successor/work dependency.
    function claimFincr() external nonReentrant returns (uint256 amount) {
        _checkpoint();
        amount = fincrCredit[msg.sender];
        fincrCredit[msg.sender] = 0;
        totalFincrCredits -= amount;
        totalFincrPaid += amount;
        if (amount != 0) _sendExact(fincr, msg.sender, amount);
        emit FincrClaimed(msg.sender, amount);
    }

    function claimImd() external nonReentrant returns (uint256 amount) {
        amount = outgoingCredit[msg.sender];
        outgoingCredit[msg.sender] = 0;
        totalOutgoingCredits -= amount;
        totalImdPaid += amount;
        if (amount != 0) _sendExact(imd, msg.sender, amount);
        emit ImdClaimed(msg.sender, amount);
    }

    /// @notice Only the immutable beneficiary's own Operations bucket, never work/reserve funds.
    function claimOperations() external nonReentrant returns (uint256 amount) {
        if (msg.sender != operationsRecipient) revert Unauthorized();
        amount = operationsBudget;
        operationsBudget = 0;
        totalImdPaid += amount;
        if (amount != 0) _sendExact(imd, msg.sender, amount);
        emit OperationsClaimed(msg.sender, amount);
    }

    /// @notice All unpaid scheduled financier rewards, including uncheckpointed active accrual.
    function financierLiability() public view returns (uint256) {
        (uint256 f,) = EmissionSchedule.split(miningReserve, elapsed());
        return f - totalFincrPaid;
    }

    function unscheduledReserve() external view returns (uint256) {
        return miningReserve - EmissionSchedule.gross(miningReserve, elapsed());
    }

    function requiredFincrCustody() public view returns (uint256) {
        return miningReserve - totalFincrPaid - totalAgentPaid;
    }

    /// @notice Base prototype stays disabled. Integrated variant constructs an immutable module.
    function agentController() public view virtual returns (address) {
        return address(0);
    }

    function agentUnpaid() public view returns (uint256) {
        return agentReserved() - totalAgentPaid;
    }

    event AgentRewardPaid(address indexed beneficiary, uint256 amount, uint256 totalPaid);

    /// @dev Only the immutable round module; no agent callback is added to bids/financier claims.
    function payAgentReward(address beneficiary, uint256 amount) external nonReentrant {
        address controller = agentController();
        if (controller == address(0) || msg.sender != controller) revert Unauthorized();
        if (beneficiary == address(0) || beneficiary == address(this) || amount > agentUnpaid()) revert Unfunded();
        totalAgentPaid += amount;
        if (amount != 0) _sendExact(fincr, beneficiary, amount);
        emit AgentRewardPaid(beneficiary, amount, totalAgentPaid);
    }

    function imdLiability() public view returns (uint256) {
        return totalOutgoingCredits + workBudget + buybackBudget + liquidityBudget + operationsBudget;
    }

    function _receiveExact(IERC20 token, address payer, uint256 amount) internal {
        uint256 beforeVault = token.balanceOf(address(this));
        uint256 beforePayer = token.balanceOf(payer);
        token.safeTransferFrom(payer, address(this), amount);
        uint256 afterVault = token.balanceOf(address(this));
        uint256 afterPayer = token.balanceOf(payer);
        if (
            afterVault < beforeVault || afterVault - beforeVault != amount || afterPayer > beforePayer
                || beforePayer - afterPayer != amount
        ) revert InexactTransfer();
    }

    function _sendExact(IERC20 token, address recipient, uint256 amount) internal {
        uint256 beforeVault = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 afterVault = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(recipient);
        if (
            afterVault > beforeVault || beforeVault - afterVault != amount || afterRecipient < beforeRecipient
                || afterRecipient - beforeRecipient != amount
        ) revert InexactTransfer();
    }
}
