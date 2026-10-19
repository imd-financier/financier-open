// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FinancierMiningWithSettlement} from "./FinancierMiningWithSettlement.sol";
import {PermanentV4Market} from "./market/PermanentV4Market.sol";

/// @notice Automatic, bucket-restricted MVP. Spot bounds are not independent price protection.
/// All optional distribution calls are gas-capped and revert in isolation, never undoing a bid.
contract FinancierMiningWithMarket is FinancierMiningWithSettlement {
    PermanentV4Market public immutable market;
    uint256 public constant RECOMMENDED_BID_GAS = 2_000_000; // Optional work may be skipped by minimum gas estimates.
    uint256 public constant MIN_MARKET_BATCH = 1e15;
    uint256 public constant AUTO_MARKET_GAS = 600_000;
    uint256 public constant AUTO_OPERATIONS_GAS = 100_000;
    uint256 public constant COMPLETION_GAS = 80_000;
    uint256 public totalBuybackSpent;
    uint256 public totalFincrBurned;
    uint256 public totalLiquiditySpent;
    uint256 public totalWorkFunding;
    event WorkFunded(address indexed payer, uint256 amount);
    event BuybackExecuted(uint256 imd, uint256 burned, uint256 supplyAfter);
    event SupplementalLiquidityExecuted(
        uint256 imd, uint256 bought, uint128 liquidity, bytes32 indexed salt, uint256 dust
    );
    event MarketDeferred(bool indexed lp, uint256 budget, bytes32 reason);
    event OperationsImdPaid(address indexed recipient, uint256 amount);
    event OperationsImdFallback(address indexed recipient, uint256 amount, bytes32 reason);

    struct Config {
        address fincr;
        address imd;
        uint256 supply;
        uint256 quote;
        uint256 floor;
        address initializer;
        address operations;
        address authority;
        bytes32 policy;
        uint256 roundSeconds;
        uint256 grace;
        uint256 maxAge;
        uint256 maxMarketBatch;
    }

    constructor(Config memory c)
        FinancierMiningWithSettlement(
            c.fincr,
            c.imd,
            c.supply,
            c.quote,
            c.floor,
            c.initializer,
            c.operations,
            c.authority,
            c.policy,
            c.roundSeconds,
            c.grace,
            c.maxAge
        )
    {
        if (c.imd != 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127) {
            revert InvalidConfiguration();
        }
        market = new PermanentV4Market(c.fincr, c.maxMarketBatch);
        // Check after child creation too: a predicted child address is not an EOA.
        if (c.operations.code.length != 0) revert InvalidConfiguration();
    }

    /// @notice Voluntary IMD funding of FINANCIER work only. No bid, reward or authority rights.
    /// @dev Kept separate from bid volume; cannot move reserve or other protected budgets.
    function fundWork(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidConfiguration();
        _receiveExact(imd, msg.sender, amount);
        workBudget += amount;
        totalWorkFunding += amount;
        emit WorkFunded(msg.sender, amount);
    }

    function _afterTakeoverPayment(address previous, uint256 outgoing) internal override {
        if (outgoing != 0 && gasleft() < AUTO_PAYOUT_GAS + PAYOUT_GAS_RESERVE + 5_000) {
            emit OutgoingImdFallback(previous, outgoing, "gas-threshold");
        } else {
            super._afterTakeoverPayment(previous, outgoing);
        }
        uint256 ops = operationsBudget;
        if (ops != 0) {
            (bool ok, bytes32 reason) = _attempt(abi.encodeCall(this.payOperationsExact, ()), AUTO_OPERATIONS_GAS);
            if (ok) emit OperationsImdPaid(operationsRecipient, ops);
            else emit OperationsImdFallback(operationsRecipient, ops, reason);
        }
        _attemptMarket(false);
        _attemptMarket(true);
    }

    function _attemptMarket(bool lp) private {
        uint256 budget = lp ? liquidityBudget : buybackBudget;
        if (budget < MIN_MARKET_BATCH) {
            if (budget != 0) emit MarketDeferred(lp, budget, "below-minimum");
            return;
        }
        (bool ok, bytes32 reason) = _attempt(abi.encodeCall(this.executeMarket, (lp)), AUTO_MARKET_GAS);
        if (!ok) emit MarketDeferred(lp, budget, reason);
    }

    /// @dev Reserve tail gas and copy at most one revert word; hostile returndata cannot amplify costs.
    function _attempt(bytes memory data, uint256 cap) private returns (bool ok, bytes32 reason) {
        if (gasleft() < cap + COMPLETION_GAS) return (false, "gas-threshold");
        assembly ("memory-safe") {
            ok := call(cap, address(), 0, add(data, 32), mload(data), 0, 0)
            let p := mload(0x40)
            mstore(p, 0)
            let n := returndatasize()
            if gt(n, 32) { n := 32 }
            returndatacopy(p, 0, n)
            reason := mload(p)
        }
    }

    /// @notice Self-call only, with bid's shared reentrancy guard already entered.
    /// Failed/inexact transfers restore the entire fallback credit and all token changes.
    function payOperationsExact() external {
        if (msg.sender != address(this)) revert Unauthorized();
        uint256 amount = operationsBudget;
        operationsBudget = 0;
        totalImdPaid += amount;
        _sendExact(imd, operationsRecipient, amount);
    }

    /// @notice Self-call only. Each successful bid attempts both buckets independently.
    /// No market operator or external caller can select targets, amounts, price bounds or recipients.
    function executeMarket(bool lp) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (!armed) revert NotArmed();
        if (imd.balanceOf(address(this)) < imdLiability() || fincr.balanceOf(address(this)) < requiredFincrCustody()) {
            revert Unfunded();
        }
        uint256 budget = lp ? liquidityBudget : buybackBudget;
        uint256 amount = budget < market.maxBatch() ? budget : market.maxBatch();
        PermanentV4Market.Order memory o = market.makeOrder(amount, lp);
        uint256 beforeImd = imd.balanceOf(address(this));
        uint256 beforeFincr = fincr.balanceOf(address(this));
        if (lp) liquidityBudget -= amount;
        else buybackBudget -= amount;
        _sendExact(imd, address(market), amount);
        PermanentV4Market.Result memory r = market.execute(o, lp);
        if (
            r.spent > amount || imd.balanceOf(address(this)) != beforeImd - r.spent
                || fincr.balanceOf(address(this)) != beforeFincr
        ) revert InexactTransfer();
        totalImdPaid += r.spent;
        if (lp) {
            liquidityBudget += amount - r.spent;
            totalLiquiditySpent += r.spent;
            emit SupplementalLiquidityExecuted(r.spent, r.bought, r.liquidity, r.salt, r.fincrDust);
        } else {
            if (r.spent != amount) revert InexactTransfer();
            totalBuybackSpent += r.spent;
            totalFincrBurned += r.bought;
            emit BuybackExecuted(r.spent, r.bought, fincr.totalSupply());
        }
    }
}
