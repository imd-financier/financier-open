// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV4Market} from "./IV4Market.sol";

interface IBurnableFincr {
    function burn(uint256 amount) external;
}

/// @notice Direct v4 exact-input buys and separate, positive-only permanent positions.
/// No upgrade, owner setter, arbitrary call, approval, removal, fee collect, rescue or migration.
/// Every LP addition has a fresh salt: it cannot collect old positions' fees or principal.
contract PermanentV4Market {
    using SafeERC20 for IERC20;
    address public constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant GUARD = 0x19Bec7C2E1b2aadAf67b259744751a9960d66000;
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 public constant MANAGER_HASH = 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 public constant GUARD_HASH = 0x23b24704ce73f4f12137de2ae4a727aa53f7dec9b66b33bd4ddb6073872833cb;
    bytes32 public constant IMD_HASH = 0xa9a0e893f7d8327fe96f823291ad9199af5456c2f9fd80bbdeff29d1e91a93e2;
    uint256 private constant Q96 = 1 << 96;
    // Full usable range for the one supported static-fee, spacing-60 pool.
    int24 public constant LOWER = -887220;
    int24 public constant UPPER = 887220;
    uint160 public constant SQRT_LOWER = 4306310044;
    uint160 public constant SQRT_UPPER = 1457652066949847389969617340386294118487833376468;
    uint256 public constant MIN_BATCH = 1e15; // 0.001 IMD; smaller buckets accumulate.
    uint256 public constant MAX_DEADLINE = 60;
    uint256 public constant SQRT_DEVIATION_BPS = 50; // about 1% price, NOT MEV immunity
    uint256 public constant OUTPUT_SLIPPAGE_BPS = 100;
    address public immutable vault;
    IERC20 public immutable fincr;
    bytes32 public immutable fincrHash;
    uint256 public immutable maxBatch;
    bytes32 public immutable poolId;
    bool public immutable imdIs0;
    uint256 public positions;
    uint256 public totalLiquidity;
    uint256 public strandedFincrDust;
    bytes32 private pending;

    struct Order {
        uint256 amount;
        uint256 minOut;
        uint256 minLiquidity;
        uint256 deadline;
    }

    struct Result {
        uint256 bought;
        uint256 spent;
        uint128 liquidity;
        bytes32 salt;
        uint256 fincrDust;
    }
    error Unsupported();
    error Unauthorized();
    error PriceBounds();
    error Bounds();
    error Callback();
    error Settlement();
    event PermanentLiquidity(
        bytes32 indexed poolId, bytes32 indexed salt, uint128 liquidity, uint256 imd, uint256 fincr, uint256 dust
    );
    event GenuineBurn(bytes32 indexed poolId, uint256 imdSpent, uint256 fincrBurned, uint256 supplyAfter);

    constructor(address token, uint256 maxBatch_) {
        if (
            block.chainid != 4663 || token == IMD || token.code.length == 0 || maxBatch_ < MIN_BATCH
                || maxBatch_ > 1 ether
        ) revert Unsupported();
        vault = msg.sender;
        fincr = IERC20(token);
        maxBatch = maxBatch_;
        fincrHash = token.codehash;
        imdIs0 = IMD < token;
        poolId = keccak256(abi.encode(key()));
        _runtime();
    }

    function key() public view returns (IV4Market.PoolKey memory) {
        return IV4Market.PoolKey(imdIs0 ? IMD : address(fincr), imdIs0 ? address(fincr) : IMD, 12500, 60, GUARD);
    }

    function spot() public view returns (uint160) {
        return uint160(uint256(IV4Market(MANAGER).extsload(keccak256(abi.encode(poolId, uint256(6))))));
    }

    function positionLiquidity(bytes32 salt) public view returns (uint128) {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), LOWER, UPPER, salt));
        bytes32 slot = keccak256(abi.encode(positionKey, uint256(keccak256(abi.encode(poolId, uint256(6)))) + 6));
        return uint128(uint256(IV4Market(MANAGER).extsload(slot)));
    }

    function _runtime() private view {
        if (
            block.chainid != 4663 || MANAGER.codehash != MANAGER_HASH || GUARD.codehash != GUARD_HASH
                || IMD.codehash != IMD_HASH || address(fincr).codehash != fincrHash
        ) revert Unsupported();
    }

    function validate(Order calldata o, bool lp) external view {
        _validate(o, lp);
    }

    function _validate(Order memory o, bool lp) private view returns (uint160 low, uint160 high) {
        _runtime();
        if (
            o.amount < MIN_BATCH || o.amount > maxBatch || o.deadline < block.timestamp
                || o.deadline > block.timestamp + MAX_DEADLINE || (lp ? o.minLiquidity == 0 : o.minLiquidity != 0)
        ) revert Bounds();
        // Founder-directed MVP: a transaction-local SPOT anchor, not an oracle.
        // Pre-transaction manipulation is NOT detected by these movement bounds.
        uint160 fair = spot();
        if (fair <= SQRT_LOWER || fair >= SQRT_UPPER) revert PriceBounds();
        low = uint160(Math.mulDiv(fair, 10000 - SQRT_DEVIATION_BPS, 10000));
        high = uint160(Math.mulDiv(fair, 10000 + SQRT_DEVIATION_BPS, 10000));
        if (low <= SQRT_LOWER || high >= SQRT_UPPER) revert PriceBounds();
        uint256 input = lp ? o.amount / 2 : o.amount;
        uint256 floor = _minimumOutput(input, fair);
        if (floor == 0 || o.minOut < floor) revert Bounds();
    }

    function _minimumOutput(uint256 input, uint160 price) private view returns (uint256) {
        uint256 quoted = imdIs0
            ? Math.mulDiv(Math.mulDiv(input, price, Q96), price, Q96)
            : Math.mulDiv(Math.mulDiv(input, Q96, price), Q96, price);
        return Math.mulDiv(Math.mulDiv(quoted, 987500, 1e6), 10000 - OUTPUT_SLIPPAGE_BPS, 10000);
    }

    /// @notice Deterministic order for the vault, anchored to current pool spot.
    /// No external price authority, operator-selected slippage or beneficiary.
    function makeOrder(uint256 amount, bool lp) external view returns (Order memory o) {
        uint160 price = spot();
        uint256 input = lp ? amount / 2 : amount;
        o = Order(amount, _minimumOutput(input, price), 0, block.timestamp);
        if (lp) {
            uint160 low = uint160(Math.mulDiv(price, 10000 - SQRT_DEVIATION_BPS, 10000));
            uint160 high = uint160(Math.mulDiv(price, 10000 + SQRT_DEVIATION_BPS, 10000));
            if (low <= SQRT_LOWER || high >= SQRT_UPPER) revert PriceBounds();
            o.minLiquidity =
                Math.min(_liquidityAt(low, amount - input, o.minOut), _liquidityAt(high, amount - input, o.minOut));
        }
        _validate(o, lp);
    }

    function execute(Order calldata o, bool lp) external returns (Result memory r) {
        if (msg.sender != vault) revert Unauthorized();
        if (pending != 0) revert Callback();
        (uint160 low, uint160 high) = _validate(o, lp);
        uint256 imdBefore = IERC20(IMD).balanceOf(address(this));
        if (imdBefore < o.amount) revert Settlement();
        uint256 fincrBefore = fincr.balanceOf(address(this));
        bytes memory data = abi.encode(o, lp, positions, low, high);
        pending = keccak256(data);
        r = abi.decode(IV4Market(MANAGER).unlock(data), (Result));
        if (pending != 0) revert Callback();
        if (!lp) {
            uint256 supply = fincr.totalSupply();
            IBurnableFincr(address(fincr)).burn(r.bought);
            if (fincr.totalSupply() != supply - r.bought || fincr.balanceOf(address(this)) != fincrBefore) {
                revert Settlement();
            }
            emit GenuineBurn(poolId, r.spent, r.bought, fincr.totalSupply());
        } else {
            if (positionLiquidity(r.salt) != r.liquidity || r.liquidity == 0) revert Settlement();
            ++positions;
            totalLiquidity += r.liquidity;
            strandedFincrDust += r.fincrDust;
            if (fincr.balanceOf(address(this)) != fincrBefore + r.fincrDust) revert Settlement();
            _send(IERC20(IMD), vault, o.amount - r.spent);
        }
        if (IERC20(IMD).balanceOf(address(this)) != imdBefore - o.amount) revert Settlement();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != MANAGER || pending == 0 || pending != keccak256(data)) revert Callback();
        pending = 0; // single callback, before all external token interactions
        (Order memory o, bool lp, uint256 nonce, uint160 low, uint160 high) =
            abi.decode(data, (Order, bool, uint256, uint160, uint160));
        uint256 input = lp ? o.amount / 2 : o.amount;
        int256 d = IV4Market(MANAGER).swap(key(), IV4Market.SwapParams(imdIs0, -int256(input), imdIs0 ? low : high), "");
        int128 dm = imdIs0 ? int128(d >> 128) : int128(d);
        int128 df = imdIs0 ? int128(d) : int128(d >> 128);
        if (int256(dm) != -int256(input) || df <= 0 || uint128(df) < o.minOut || spot() < low || spot() > high) {
            revert PriceBounds();
        }
        _settle(IMD, dm);
        _settle(address(fincr), df);
        Result memory r;
        r.bought = uint128(df);
        r.spent = input;
        if (lp) r = _add(r, o.amount - input, o.minLiquidity, nonce);
        return abi.encode(r);
    }

    function _liquidityAt(uint160 price, uint256 imdAvailable, uint256 fincrAvailable) private view returns (uint128) {
        uint256 a0 = imdIs0 ? imdAvailable : fincrAvailable;
        uint256 a1 = imdIs0 ? fincrAvailable : imdAvailable;
        uint256 l0 = Math.mulDiv(a0, Math.mulDiv(price, SQRT_UPPER, Q96), SQRT_UPPER - price);
        uint256 l1 = Math.mulDiv(a1, Q96, price - SQRT_LOWER);
        uint256 liq = Math.min(l0, l1);
        if (liq == 0 || liq > uint128(type(int128).max)) revert Bounds();
        return uint128(liq);
    }

    function _add(Result memory r, uint256 available, uint256 minimum, uint256 nonce) private returns (Result memory) {
        r.liquidity = _liquidityAt(spot(), available, r.bought);
        if (r.liquidity < minimum) revert Bounds();
        r.salt = keccak256(abi.encode("FINANCIER permanent supplemental LP v1", nonce));
        if (positionLiquidity(r.salt) != 0) revert Settlement();
        (int256 d,) = IV4Market(MANAGER)
            .modifyLiquidity(
                key(), IV4Market.ModifyLiquidityParams(LOWER, UPPER, int256(uint256(r.liquidity)), r.salt), ""
            );
        int128 dm = imdIs0 ? int128(d >> 128) : int128(d);
        int128 df = imdIs0 ? int128(d) : int128(d >> 128);
        if (dm >= 0 || df >= 0 || uint256(-int256(dm)) > available || uint256(-int256(df)) > r.bought) {
            revert Settlement();
        }
        _settle(IMD, dm);
        _settle(address(fincr), df);
        r.spent += uint256(-int256(dm));
        r.fincrDust = r.bought - uint256(-int256(df));
        emit PermanentLiquidity(poolId, r.salt, r.liquidity, uint256(-int256(dm)), uint256(-int256(df)), r.fincrDust);
        return r;
    }

    function _settle(address token, int128 delta) private {
        IERC20 t = IERC20(token);
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            IV4Market(MANAGER).sync(token);
            _send(t, MANAGER, amount);
            if (IV4Market(MANAGER).settle() != amount) revert Settlement();
        } else if (delta > 0) {
            uint256 before = t.balanceOf(address(this));
            IV4Market(MANAGER).take(token, address(this), uint128(delta));
            if (t.balanceOf(address(this)) != before + uint128(delta)) revert Settlement();
        }
    }

    function _send(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 fromBefore = token.balanceOf(address(this));
        uint256 toBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) != fromBefore - amount || token.balanceOf(to) != toBefore + amount) {
            revert Settlement();
        }
    }
}
