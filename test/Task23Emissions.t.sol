// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {EmissionSchedule} from "../src/EmissionSchedule.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Test-only authorization stub; production remains the immutable D-020 round module.
contract EmissionVaultHarness is FinancierMining {
    constructor(address f, address i, uint256 supply)
        FinancierMining(f, i, supply, 0.0001 ether, 0, msg.sender, address(105))
    {}

    function agentController() public pure override returns (address) {
        return address(750);
    }
}

abstract contract EmissionFixture is Test {
    uint256 constant SUPPLY = 1e27;
    uint256 constant RESERVE = 4e26;
    MockToken fincr;
    MockToken imd;
    EmissionVaultHarness vault;

    function setUp() public virtual {
        vm.warp(1_000_000);
        fincr = new MockToken();
        imd = new MockToken();
        fincr.mint(address(this), SUPPLY);
        vault = new EmissionVaultHarness(address(fincr), address(imd), SUPPLY);
        fincr.transfer(address(vault), RESERVE);
        vault.arm();
        for (uint256 i; i < 3; i++) {
            address a = address(uint160(101 + i));
            imd.mint(a, 1e60);
            vm.prank(a);
            imd.approve(address(vault), type(uint256).max);
        }
    }

    function bid(address who) internal {
        uint256 e = vault.epoch();
        uint256 p = vault.currentPrice();
        vm.prank(who);
        vault.bid(e, p, block.timestamp);
    }
}

contract Task23EmissionsTest is EmissionFixture {
    function testNoRewardsOrClockBeforeFirstBidRegardlessOfArmingDelay() public {
        vm.warp(block.timestamp + 500 days);
        assertEq(vault.genesis(), 0);
        assertEq(vault.elapsed(), 0);
        assertEq(vault.agentReserved(), 0);
        assertEq(vault.claimableFincr(address(101)), 0);
        vm.prank(address(101));
        assertEq(vault.claimFincr(), 0);
        bid(address(101));
        assertEq(vault.genesis(), block.timestamp);
        assertEq(vault.claimableFincr(address(101)), 0);
    }

    function testSameBlockAndRapidTakeoversHaveNoDuplicateEmission() public {
        for (uint256 i; i < 12; i++) {
            address a = address(uint160(101 + i % 3));
            bid(a);
            vm.prank(a);
            assertEq(vault.claimFincr(), 0);
        }
        assertEq(vault.financierCursor(), 0);
        assertEq(vault.totalFincrPaid(), 0);
        vm.warp(block.timestamp + 1);
        address last = vault.iFinancier();
        (, uint256 f, uint256 a) = vault.cumulativeAt(1);
        vm.prank(last);
        assertEq(vault.claimFincr(), f);
        vm.prank(last);
        assertEq(vault.claimFincr(), 0);
        assertEq(vault.agentReserved(), a);
    }

    function testFinalAndFormerFinanciersPlusAgentPaymentsExhaustExactlyReserve() public {
        bid(address(101));
        uint256 g = vault.genesis();
        vm.warp(g + 14 days);
        bid(address(102));
        vm.warp(g + 365 days); // final holder never needs a successor
        uint256 agent = vault.agentUnpaid();
        vm.prank(address(750));
        vault.payAgentReward(address(103), agent);
        uint256 before = vault.totalAgentPaid();
        vm.prank(address(101));
        uint256 former = vault.claimFincr();
        vm.prank(address(102));
        uint256 last = vault.claimFincr();
        assertGt(former, 0);
        assertGt(last, 0);
        assertEq(before, vault.totalAgentPaid());
        assertEq(former + last, RESERVE * 4 / 5);
        assertEq(agent, RESERVE / 5);
        assertEq(fincr.balanceOf(address(vault)), 0);
        assertEq(vault.requiredFincrCustody(), 0);
        vm.warp(g + 1000 days);
        vm.prank(address(102));
        assertEq(vault.claimFincr(), 0);
        assertEq(vault.agentUnpaid(), 0);
    }

    function testFuzzReserveSplitAndExactDay365(uint256 raw, uint32 elapsed) public pure {
        uint256 supply = bound(raw, 1, type(uint256).max / 100) * 100;
        uint256 reserve = Math.mulDiv(supply, 40, 100);
        assertEq(reserve, supply / 100 * 40);
        uint256 t = uint256(elapsed) % (730 days);
        uint256 e = EmissionSchedule.gross(reserve, t);
        (uint256 f, uint256 a) = EmissionSchedule.split(reserve, t);
        assertEq(f, Math.mulDiv(e, 80, 100));
        assertEq(a, e - f);
        assertLe(e, reserve);
        (uint256 ff, uint256 aa) = EmissionSchedule.split(reserve, 365 days);
        assertEq(ff, reserve / 5 * 4);
        assertEq(aa, reserve / 5);
        assertEq(ff + aa, reserve);
    }

    function testFuzzTinyIntervalsTelescopeWithoutRoundingLoss(uint256 seed, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 48);
        bid(address(101));
        uint256 g = vault.genesis();
        uint256 total;
        uint256 t;
        for (uint256 i; i < count; i++) {
            t += uint256(keccak256(abi.encode(seed, i))) % 3;
            vm.warp(g + t);
            address owner = vault.iFinancier();
            vm.prank(owner);
            total += vault.claimFincr();
            // Zero-time takeovers are included; price doubling stays within funded test balances.
            bid(address(uint160(101 + i % 3)));
        }
        (, uint256 f, uint256 a) = vault.cumulativeAt(t);
        assertEq(total, f);
        assertEq(vault.agentReserved(), a);
        assertEq(fincr.balanceOf(address(vault)) + total, RESERVE);
    }
}

contract EmissionSequenceHandler is Test {
    EmissionVaultHarness public vault;

    constructor(EmissionVaultHarness v) {
        vault = v;
    }

    function advance(uint32 t) external {
        vm.warp(block.timestamp + uint256(t) % 20 days);
    }

    function bid(uint8 who) external {
        uint256 e = vault.epoch();
        uint256 p = vault.currentPrice();
        vm.prank(address(uint160(101 + who % 3)));
        vault.bid(e, p, block.timestamp);
    }

    function financierClaim(uint8 who) external {
        vm.prank(address(uint160(101 + who % 3)));
        vault.claimFincr();
    }

    function agentClaim(uint256 raw) external {
        uint256 available = vault.agentUnpaid();
        uint256 amount = available == 0 ? 0 : raw % (available + 1);
        vm.prank(address(750));
        vault.payAgentReward(address(103), amount);
    }
}

contract Task23EmissionInvariantTest is EmissionFixture {
    function setUp() public override {
        super.setUp();
        EmissionSequenceHandler h = new EmissionSequenceHandler(vault);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = h.advance.selector;
        selectors[1] = h.bid.selector;
        selectors[2] = h.financierClaim.selector;
        selectors[3] = h.agentClaim.selector;
        targetSelector(FuzzSelector(address(h), selectors));
        targetContract(address(h));
    }

    function invariantFiniteCumulativeSplitClaimsAndSolvency() public view {
        (uint256 gross, uint256 f, uint256 a) = vault.cumulativeAt(vault.elapsed());
        assertEq(vault.miningReserve(), RESERVE);
        assertEq(gross, f + a);
        assertLe(gross, RESERVE);
        assertEq(f, Math.mulDiv(gross, 4, 5));
        assertLe(vault.totalAgentPaid(), a);
        assertLe(vault.totalFincrPaid(), f);
        assertLe(vault.financierCursor(), f);
        uint256 claims;
        for (uint256 i; i < 3; i++) {
            claims += vault.claimableFincr(address(uint160(101 + i)));
        }
        assertEq(claims + vault.totalFincrPaid(), f);
        assertEq(fincr.balanceOf(address(vault)) + vault.totalFincrPaid() + vault.totalAgentPaid(), RESERVE);
        assertEq(vault.requiredFincrCustody(), fincr.balanceOf(address(vault)));
        assertEq(imd.balanceOf(address(vault)), vault.imdLiability());
        if (vault.epoch() == 0) {
            assertEq(gross, 0);
            assertEq(vault.genesis(), 0);
        }
        if (vault.elapsed() >= 365 days) assertEq(gross, RESERVE);
    }
}
