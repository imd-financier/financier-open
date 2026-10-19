// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task15Base, Mining, Rounds, Receiver} from "./helpers/Task15Base.sol";
import {Test} from "forge-std/Test.sol";
import {IAgentWorkVerifier} from "../src/interfaces/IAgentWorkVerifier.sol";

/// Authority impersonation and ownership are SYNTHETIC; actual budgets/auction/claims execute.
contract Task15Handler is Test {
    Mining public immutable miner;
    Rounds public immutable rounds;
    Receiver public immutable forwarder;
    uint256 public immutable genesis;
    uint256 public ghostCursor;
    uint256 public ghostOwner;
    uint256 public ghostPaidAgents;
    uint256 public ghostAllocated;
    uint256 public ghostQuarantined;
    uint256 public successfulSettlements;
    uint256 public successfulAgentClaims;
    uint256 public ghostVolume = 1 ether;
    uint256[2] public earned;
    uint256[2] public paidFinancier;
    uint256[32] public paidAgent;
    uint256[] private settled;
    bytes private tokenCode;
    bytes private minerCode;

    constructor(Mining m, Receiver f, bytes memory tc, bytes memory mc) {
        miner = m;
        rounds = m.agentRounds();
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
        vm.warp(block.timestamp + uint256(raw) % (6 hours + 1));
        _sync();
        uint256 id = (block.timestamp - genesis) / 1 days;
        if (id < 3) {
            bytes32 job = keccak256(abi.encode("LOCAL JOB", id));
            if (rounds.jobBoundAt(job) == 0) {
                // Isolated round invariant fixture; Task16 invariant spends the actual bucket.
                bytes32 request = keccak256(abi.encode("LOCAL REQUEST", id));
                bytes32 body = keccak256(abi.encode("LOCAL EXACT FINANCIER REQUEST BODY", id));
                vm.mockCall(
                    address(miner),
                    abi.encodeCall(miner.workRequests, (request)),
                    abi.encode(id + 1, body, block.timestamp)
                );
                vm.prank(address(702));
                rounds.bindJob(
                    id,
                    Rounds.Admission(
                        keccak256(abi.encode("LOCAL REQUEST", id)),
                        job,
                        keccak256(abi.encode("LOCAL EXACT FINANCIER REQUEST BODY", id)),
                        block.timestamp,
                        block.timestamp,
                        keccak256("MOCK official Intake/backend admission")
                    )
                );
            }
        }
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
        uint256 id = uint256(rawId) % 3;
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
        uint256 boundAt = rounds.jobBoundAt(keccak256(abi.encode("LOCAL JOB", id)));
        if (boundAt == 0 || boundAt + 2 >= c.end) n = 0;
        IAgentWorkVerifier.Contribution[] memory a = new IAgentWorkVerifier.Contribution[](n);
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(301 + i));
            bytes32 salt = keccak256(abi.encode(id, i));
            a[i] = IAgentWorkVerifier.Contribution(
                1,
                rounds.IDENTITY_REGISTRY(),
                i + 1,
                who,
                who,
                keccak256(abi.encode("LOCAL JOB", id)),
                keccak256(abi.encode("receipt", salt)),
                keccak256(abi.encode("submission", salt)),
                keccak256(abi.encode("artifact", salt)),
                boundAt + 2,
                c.end - 15 minutes,
                c.deadline
            );
        }
        Rounds.Snapshot memory snapshot = Rounds.Snapshot(
            123456 + id,
            keccak256(abi.encode("MOCK BLOCK", id)),
            c.end - 15 minutes,
            keccak256("MOCK OWNERS"),
            keccak256("MOCK COMPLETE SET")
        );
        Rounds.OwnerEvidence[] memory owners = new Rounds.OwnerEvidence[](n);
        for (uint256 i; i < n; ++i) {
            owners[i] = Rounds.OwnerEvidence(i + 1, false, 0, 0, boundAt + 1);
        }
        bytes32 digest = rounds.settlementCommitment(id, a, snapshot, owners);
        vm.prank(address(702));
        rounds.finalize(id, a, snapshot, owners, digest);
        ++successfulSettlements;
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
        ++successfulAgentClaims;
        assertEq(paid, credit);
        ghostPaidAgents += paid;
        paidAgent[who] += paid;
        vm.prank(recipient);
        (bool ok,) = address(rounds).call(abi.encodeCall(rounds.claim, (id)));
        assertFalse(ok);
    }

    function replayForwardOrUnauthorizedPayout(uint256 amount) external {
        vm.prank(address(701));
        (bool ok,) = address(forwarder)
            .call(abi.encodeCall(forwarder.bootstrap, (uint64(15001), tokenCode, minerCode, keccak256("LOCAL REVIEW"))));
        assertFalse(ok);
        (ok,) = address(miner).call(abi.encodeCall(miner.payAgentReward, (address(this), amount)));
        assertFalse(ok);
    }
}

contract Task15InvariantTest is Task15Base {
    Task15Handler internal handler;
    uint256 internal originalGenesis;

    function setUp() public override {
        super.setUp();
        start();
        originalGenesis = miner.genesis();
        imd.mint(ALICE, 1e65);
        imd.mint(BOB, 1e65);
        handler = new Task15Handler(miner, receiver, tokenInit, minerInit);
        // Ensure conservation checks are not vacuous even for an outage-heavy random sequence.
        for (uint256 i; i < 4; ++i) {
            handler.advance(uint32(6 hours));
        }
        handler.settle(3, 0);
        handler.agentClaim(0, 0);
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
        assertGt(handler.successfulSettlements(), 0);
        assertGt(handler.successfulAgentClaims(), 0);
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
        assertTrue(receiver.bootstrapped());
        assertEq(token.balanceOf(address(receiver)), 0);
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
