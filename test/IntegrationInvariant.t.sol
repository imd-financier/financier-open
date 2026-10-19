// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IntegrationBase} from "./helpers/IntegrationBase.sol";
import {Test} from "forge-std/Test.sol";
import {FinancierMiningWithAgents} from "../src/FinancierMiningWithAgents.sol";
import {ReserveForwarder} from "../src/ReserveForwarder.sol";
import {AgentRounds} from "../src/AgentRounds.sol";
import {FINCR} from "../src/FINCR.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {RoundVerifierMock} from "./helpers/RoundVerifierMock.sol";
import {IAgentWorkVerifier} from "../src/interfaces/IAgentWorkVerifier.sol";

/// Generated proof authority exists ONLY in this handler's mock. No production proof is assumed.
contract IntegrationHandler is Test {
    FinancierMiningWithAgents public immutable miner;
    AgentRounds public immutable rounds;
    RoundVerifierMock public immutable verifier;
    ReserveForwarder public immutable forwarder;
    uint256 public immutable genesis;
    uint256 public ghostCursor;
    uint256 public ghostOwner;
    uint256 public ghostPaidAgents;
    uint256 public ghostAllocated;
    uint256 public ghostQuarantined;
    uint256 public ghostVolume = 1 ether;
    uint256[2] public earned;
    uint256[2] public paidFinancier;
    uint256[32] public paidAgent;
    uint256[] private settled;
    bytes private tokenCode;
    bytes private minerCode;

    constructor(
        FinancierMiningWithAgents m,
        RoundVerifierMock v,
        ReserveForwarder f,
        bytes memory tc,
        bytes memory mc
    ) {
        miner = m;
        rounds = m.agentRounds();
        verifier = v;
        forwarder = f;
        genesis = m.genesis();
        tokenCode = tc;
        minerCode = mc;
    }

    function _sync() private {
        (, uint256 total,) = miner.cumulativeAt(block.timestamp - genesis);
        earned[ghostOwner] += total - ghostCursor;
        ghostCursor = total;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + uint256(raw) % (30 days + 1));
        _sync();
    }

    function bid(uint8 raw) external {
        _sync();
        uint256 who = raw % 2;
        uint256 p = miner.currentPrice();
        uint256 epoch = miner.epoch();
        vm.prank(address(uint160(101 + who)));
        miner.bid(epoch, p, block.timestamp);
        ghostOwner = who;
        ghostVolume += p;
    }

    function financierClaim(uint8 raw) external {
        _sync();
        uint256 who = raw % 2;
        vm.startPrank(address(uint160(101 + who)));
        paidFinancier[who] += miner.claimFincr();
        miner.claimImd();
        vm.stopPrank();
    }

    function settle(uint8 rawCount, uint16 rawId) external {
        uint256 ended = (block.timestamp - genesis) / 1 days;
        if (ended == 0) return;
        // Exercise most recent close as well as older/expired rounds, in random order.
        uint256 id = rawId % 2 == 0 ? (ended > 365 ? 364 : ended - 1) : uint256(rawId) % 365;
        (bool done,,,,,) = rounds.rounds(id);
        if (done) return;
        IAgentWorkVerifier.Context memory c = rounds.context(id);
        if (block.timestamp < c.end) return;
        uint256 budget = miner.agentAllocation(c.start - genesis, c.end - genesis);
        if (block.timestamp > c.deadline) {
            rounds.expire(id);
            ghostQuarantined += budget;
            return;
        }
        settled.push(id);
        uint256 n = rawCount % 33;
        IAgentWorkVerifier.Contribution[] memory a = new IAgentWorkVerifier.Contribution[](n);
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(301 + i));
            bytes32 salt = keccak256(abi.encode(id, i));
            a[i] = IAgentWorkVerifier.Contribution(
                1,
                address(8004),
                i + 1,
                who,
                who,
                keccak256(abi.encode("job", id)),
                keccak256(abi.encode("receipt", salt)),
                keccak256(abi.encode("submission", salt)),
                keccak256(abi.encode("artifact", salt)),
                c.start + 1,
                block.timestamp,
                block.timestamp + 1 hours
            );
        }
        bytes32 digest = rounds.commitment(c, a);
        verifier.approve(digest, digest);
        rounds.finalize(id, a, abi.encode(digest));
        uint256 allocation = n == 0 ? 0 : budget / n * n;
        ghostAllocated += allocation;
        ghostQuarantined += budget - allocation;
    }

    function agentClaim(uint16 rawId, uint8 rawAgent) external {
        if (settled.length == 0) return;
        uint256 id = settled[rawId % settled.length];
        uint256 who = rawAgent % 32;
        address recipient = address(uint160(301 + who));
        uint256 credit = rounds.claimable(id, recipient);
        if (credit == 0) return;
        vm.prank(recipient);
        uint256 paid = rounds.claim(id);
        assertEq(paid, credit);
        ghostPaidAgents += paid;
        paidAgent[who] += paid;
        vm.prank(recipient);
        (bool ok,) = address(rounds).call(abi.encodeCall(rounds.claim, (id)));
        assertFalse(ok);
    }

    function replayForwardOrUnauthorizedPayout(uint256 amount) external {
        (bool ok,) = address(forwarder).call(abi.encodeCall(forwarder.forward, (tokenCode, minerCode)));
        assertFalse(ok);
        (ok,) = address(miner).call(abi.encodeCall(miner.payAgentReward, (address(this), amount)));
        assertFalse(ok);
    }
}

contract IntegrationInvariantTest is IntegrationBase {
    IntegrationHandler internal handler;
    uint256 internal originalGenesis;

    function setUp() public {
        deployIntegration(false);
        forwardAndStart();
        originalGenesis = miner.genesis();
        imd.mint(ALICE, 1e65);
        imd.mint(BOB, 1e65);
        handler = new IntegrationHandler(miner, verifier, forwarder, tokenCode, minerCode);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.bid.selector;
        selectors[2] = handler.financierClaim.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.agentClaim.selector;
        selectors[5] = handler.replayForwardOrUnauthorizedPayout.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantCombinedCustodyAndIsolatedRoundBudgets() public view {
        assertEq(miner.totalAgentPaid(), handler.ghostPaidAgents());
        assertEq(rounds.totalPaid(), miner.totalAgentPaid());
        assertEq(rounds.totalAllocated(), handler.ghostAllocated());
        assertEq(rounds.totalQuarantined(), handler.ghostQuarantined());
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), rounds.totalFinalizedBudget());
        assertLe(rounds.totalPaid(), rounds.totalAllocated());
        assertLe(rounds.totalFinalizedBudget(), miner.agentReserved());
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), RESERVE);
        assertEq(token.balanceOf(address(miner)), miner.requiredFincrCustody());
        assertEq(
            token.balanceOf(address(miner)),
            miner.financierLiability() + miner.agentUnpaid() + miner.unscheduledReserve()
        );
        for (uint256 i; i < 32; ++i) {
            assertEq(token.balanceOf(address(uint160(301 + i))), handler.paidAgent(i));
        }
    }

    function invariantIndependentFinanciersAndImdConservation() public view {
        uint256 paid;
        for (uint256 i; i < 2; ++i) {
            address who = address(uint160(101 + i));
            assertEq(handler.earned(i), handler.paidFinancier(i) + miner.claimableFincr(who));
            assertEq(token.balanceOf(who), handler.paidFinancier(i));
            paid += handler.paidFinancier(i);
        }
        assertEq(paid, miner.totalFincrPaid());
        assertEq(miner.genesis(), originalGenesis);
        assertTrue(forwarder.forwarded());
        assertEq(token.balanceOf(address(forwarder)), 0);
        assertEq(miner.totalBidVolume(), handler.ghostVolume());
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(miner.totalBidVolume(), miner.imdLiability() + miner.totalImdPaid());
        assertEq(
            miner.imdLiability(),
            miner.totalOutgoingCredits() + miner.workBudget() + miner.buybackBudget() + miner.liquidityBudget()
                + miner.operationsBudget()
        );
    }

    function afterInvariant() public {
        vm.warp(block.timestamp + 366 days);
        handler.advance(0);
        handler.financierClaim(0);
        handler.financierClaim(1);
        assertEq(miner.totalFincrPaid(), 320_000_000 ether);
        assertEq(miner.financierLiability(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid(), 80_000_000 ether);
    }
}
