// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FinancierMiningWithMarket as Mining} from "../../src/FinancierMiningWithMarket.sol";
import {PermanentV4Market as Market} from "../../src/market/PermanentV4Market.sol";
import {IV4Market} from "../../src/market/IV4Market.sol";

interface IManagerInit {
    function initialize(IV4Market.PoolKey calldata, uint160) external returns (int24);
}

interface IImdTransfers {
    function enableTransfers() external;
}

/// Test-only unrestricted position actor. It never owns the market's position.
contract V4AttackActor {
    IV4Market public manager;
    IV4Market.PoolKey public pool;

    constructor(address m, IV4Market.PoolKey memory k) {
        manager = IV4Market(m);
        pool = k;
    }

    function modify(int256 liquidity, bytes32 salt) external {
        manager.unlock(abi.encode(uint8(0), liquidity, salt));
    }

    function trade(bool zeroForOne, uint256 input, uint160 limit) external {
        manager.unlock(abi.encode(uint8(1), zeroForOne, input, limit));
    }

    function donate(uint256 a, uint256 b) external {
        manager.unlock(abi.encode(uint8(2), a, b));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        uint8 mode = abi.decode(data, (uint8));
        int256 delta;
        if (mode == 0) {
            (, int256 liquidity, bytes32 salt) = abi.decode(data, (uint8, int256, bytes32));
            (delta,) =
                manager.modifyLiquidity(pool, IV4Market.ModifyLiquidityParams(-887220, 887220, liquidity, salt), "");
        } else if (mode == 1) {
            (, bool zeroForOne, uint256 input, uint160 limit) = abi.decode(data, (uint8, bool, uint256, uint160));
            delta = manager.swap(pool, IV4Market.SwapParams(zeroForOne, -int256(input), limit), "");
        } else {
            (, uint256 a, uint256 b) = abi.decode(data, (uint8, uint256, uint256));
            (bool ok, bytes memory result) = address(manager)
                .call(
                    abi.encodeWithSignature(
                        "donate((address,address,uint24,int24,address),uint256,uint256,bytes)", pool, a, b, bytes("")
                    )
                );
            require(ok);
            delta = abi.decode(result, (int256));
        }
        settle(pool.currency0, int128(delta >> 128));
        settle(pool.currency1, int128(delta));
        return "";
    }

    function settle(address t, int128 d) internal {
        if (d < 0) {
            manager.sync(t);
            IERC20(t).transfer(address(manager), uint256(-int256(d)));
            manager.settle();
        } else if (d > 0) {
            manager.take(t, address(this), uint128(d));
        }
    }
}

abstract contract Task23Base is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant GUARD = 0x19Bec7C2E1b2aadAf67b259744751a9960d66000;
    address constant FACTORY = 0x9C9D2FCB75c2C132C0AC0C42DF3819A42347265e;
    address constant SETTLER = address(702);
    address constant ALICE = address(101);
    address constant BOB = address(102);
    FINCR token;
    Mining miner;
    Market market;
    V4AttackActor actor;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_000_000);
        vm.etch(IMD, vm.parseBytes(vm.readLine("test/fixtures/task16/imd-runtime.hex")));
        vm.store(IMD, bytes32(0), bytes32(uint256(uint160(address(this)))));
        IImdTransfers(IMD).enableTransfers();
        vm.etch(MANAGER, vm.parseBytes(vm.readLine("test/fixtures/task23/manager-runtime.hex")));
        vm.etch(GUARD, vm.parseBytes(vm.readLine("test/fixtures/task23/guard-runtime.hex")));
        token = new FINCR(1e27);
        miner = new Mining(config(address(token)));
        market = miner.market();
        token.transfer(address(miner), 4e26);
        miner.arm();
        IV4Market.PoolKey memory k = market.key();
        vm.prank(FACTORY);
        IManagerInit(MANAGER).initialize(k, uint160(1 << 96));
        actor = new V4AttackActor(MANAGER, k);
        token.transfer(address(actor), 1e26);
        deal(IMD, address(actor), 1e26);
        actor.modify(int256(1e25), bytes32(0));
        deal(IMD, ALICE, 1e30);
        deal(IMD, BOB, 1e30);
        vm.prank(ALICE);
        IERC20(IMD).approve(address(miner), type(uint256).max);
        vm.prank(BOB);
        IERC20(IMD).approve(address(miner), type(uint256).max);
        vm.prank(ALICE);
        miner.bid(0, 0.1 ether, block.timestamp);
    }

    function config(address t) internal view returns (Mining.Config memory c) {
        c = Mining.Config(
            t,
            IMD,
            1e27,
            0.1 ether,
            0.1 ether,
            address(this),
            address(105),
            SETTLER,
            keccak256("TEST ONLY"),
            1 days,
            1 days,
            1 hours,
            0.1 ether
        );
    }

    function order(bool lp) internal view returns (Market.Order memory) {
        // Reference ratio 1:1, minus fixed pool fee and a strict output floor.
        return market.makeOrder(0.001 ether, lp);
    }

    function nextBid(address who) internal {
        vm.warp(block.timestamp + 1 hours);
        uint256 e = miner.epoch();
        uint256 p = miner.currentPrice();
        vm.prank(who);
        miner.bid{gas: 2_000_000}(e, p, block.timestamp);
    }

    function checkSolvent() internal view {
        assertGe(IERC20(IMD).balanceOf(address(miner)), miner.imdLiability());
        assertEq(miner.totalBidVolume() + miner.totalWorkFunding(), miner.totalImdPaid() + miner.imdLiability());
        assertGe(token.balanceOf(address(miner)), miner.requiredFincrCustody());
        assertEq(IERC20(IMD).allowance(address(market), MANAGER), 0);
        assertEq(token.allowance(address(market), MANAGER), 0);
    }
}
