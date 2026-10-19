// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract MiningHandler is Test {
    FinancierMining public immutable miner;
    MockToken public immutable fincr;
    MockToken public immutable imd;
    address[4] public actors = [address(101), address(102), address(103), address(104)];
    address public constant OPS = address(105);
    uint256 public ghostGenesis;
    uint256 public ghostEpoch;
    uint256 public ghostVolume;
    uint256 public ghostScheduledFinancier;
    uint256 public ghostOwner;
    uint256 public successfulBids;
    uint256 public successfulClaims;
    uint256[4] public earned;
    uint256[4] public paidFincr;
    uint256[4] public paidImd;

    constructor(FinancierMining miner_, MockToken fincr_, MockToken imd_) {
        miner = miner_;
        fincr = fincr_;
        imd = imd_;
        for (uint256 i; i < 4; ++i) {
            imd.mint(actors[i], 1e65);
            vm.prank(actors[i]);
            imd.approve(address(miner), type(uint256).max);
        }
    }

    function _sync() private {
        if (ghostEpoch == 0) return;
        (, uint256 cumulative,) = miner.cumulativeAt(block.timestamp - ghostGenesis);
        earned[ghostOwner] += cumulative - ghostScheduledFinancier;
        ghostScheduledFinancier = cumulative;
    }

    function advance(uint32 dt) external {
        vm.warp(block.timestamp + _bound(uint256(dt), 0, 30 days));
        _sync();
    }

    function bid(uint256 actor) external {
        actor %= 4;
        _sync();
        uint256 price = miner.currentPrice();
        vm.prank(actors[actor]);
        miner.bid(ghostEpoch, price, block.timestamp);
        if (ghostEpoch == 0) ghostGenesis = block.timestamp;
        ghostOwner = actor;
        ++ghostEpoch;
        ++successfulBids;
        ghostVolume += price;
    }

    function claim(uint256 actor) external {
        actor %= 4;
        _sync();
        uint256 beforeFincr = fincr.balanceOf(actors[actor]);
        uint256 beforeImd = imd.balanceOf(actors[actor]);
        vm.startPrank(actors[actor]);
        uint256 f = miner.claimFincr();
        uint256 i = miner.claimImd();
        vm.stopPrank();
        assertEq(fincr.balanceOf(actors[actor]) - beforeFincr, f);
        assertEq(imd.balanceOf(actors[actor]) - beforeImd, i);
        paidFincr[actor] += f;
        paidImd[actor] += i;
        ++successfulClaims;
    }

    function operationsClaim() external {
        vm.prank(OPS);
        miner.claimOperations();
    }

    function staleBid(uint256 actor) external {
        actor %= 4;
        vm.prank(actors[actor]);
        (bool ok,) =
            address(miner).call(abi.encodeCall(miner.bid, (ghostEpoch + 1, type(uint256).max, block.timestamp)));
        assertFalse(ok);
    }
}

abstract contract MiningInvariantBase is StdInvariant, Test {
    MockToken internal fincr;
    MockToken internal imd;
    FinancierMining internal miner;
    MiningHandler internal handler;
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant RESERVE = 4e26;
    function floor() internal pure virtual returns (uint256);

    function setUp() public {
        vm.warp(1_000_000);
        fincr = new MockToken();
        imd = new MockToken();
        fincr.mint(address(this), SUPPLY);
        miner = new FinancierMining(address(fincr), address(imd), SUPPLY, 1 ether, floor(), address(this), address(105));
        assertTrue(fincr.transfer(address(miner), RESERVE));
        miner.arm();
        handler = new MiningHandler(miner, fincr, imd);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.bid.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.operationsClaim.selector;
        selectors[4] = handler.staleBid.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantReserveSplitConservationAndBeneficiaryNoDoubleClaim() public view {
        uint256 totalClaims;
        uint256 totalUnpaid;
        uint256 storedCredits;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 paid = handler.paidFincr(i);
            uint256 owed = miner.claimableFincr(actor);
            assertEq(paid + owed, handler.earned(i));
            assertEq(fincr.balanceOf(actor), paid);
            totalClaims += paid;
            totalUnpaid += owed;
            storedCredits += miner.fincrCredit(actor);
        }
        (uint256 e, uint256 f, uint256 a) = miner.cumulativeAt(miner.elapsed());
        assertEq(storedCredits, miner.totalFincrCredits());
        assertEq(miner.financierCursor(), totalClaims + storedCredits);
        assertEq(totalClaims, miner.totalFincrPaid());
        assertEq(totalClaims + totalUnpaid, f);
        assertEq(totalUnpaid, miner.financierLiability());
        assertEq(a, miner.agentReserved());
        assertEq(f + a, e);
        assertLe(e, RESERVE);
        assertEq(fincr.balanceOf(address(miner)) + totalClaims, RESERVE);
        assertEq(fincr.balanceOf(address(miner)), totalUnpaid + a + miner.unscheduledReserve());
        assertEq(miner.requiredFincrCustody(), fincr.balanceOf(address(miner)));
    }

    function invariantImdPayoutsAndEveryBudgetRemainSolvent() public view {
        uint256 credits;
        uint256 paid;
        for (uint256 i; i < 4; ++i) {
            credits += miner.outgoingCredit(handler.actors(i));
            paid += handler.paidImd(i);
        }
        assertEq(credits, miner.totalOutgoingCredits());
        assertEq(paid + imd.balanceOf(address(105)), miner.totalImdPaid());
        assertEq(miner.imdLiability(), imd.balanceOf(address(miner)));
        assertEq(miner.totalBidVolume(), miner.imdLiability() + miner.totalImdPaid());
        assertEq(miner.totalBidVolume(), handler.ghostVolume());
        assertEq(
            miner.imdLiability(),
            credits + miner.workBudget() + miner.buybackBudget() + miner.liquidityBudget() + miner.operationsBudget()
        );
    }

    function invariantGenesisEpochAndPositionCannotResetOrBeSeized() public view {
        assertEq(miner.genesis(), handler.ghostGenesis());
        assertEq(miner.epoch(), handler.ghostEpoch());
        if (miner.epoch() != 0) assertEq(miner.iFinancier(), handler.actors(handler.ghostOwner()));
        else assertEq(miner.iFinancier(), address(0));
        assertGe(miner.currentPrice(), floor());
        assertLe(miner.currentPrice(), miner.MAX_RESET_PRICE());
    }

    /// @dev Exercise final holder closure after each randomized sequence, even without successors.
    function afterInvariant() public {
        if (miner.epoch() == 0) handler.bid(0);
        vm.warp(block.timestamp + 366 days);
        handler.advance(0);
        for (uint256 i; i < 4; ++i) {
            handler.claim(i);
        }
        assertEq(miner.totalFincrPaid(), RESERVE * 4 / 5);
        assertEq(miner.financierLiability(), 0);
        assertEq(fincr.balanceOf(address(miner)), RESERVE / 5);
    }
}

contract FloorMiningInvariant is MiningInvariantBase {
    function floor() internal pure override returns (uint256) {
        return 1 ether;
    }
}

contract ZeroMiningInvariant is MiningInvariantBase {
    function floor() internal pure override returns (uint256) {
        return 0;
    }
}
