// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task16Base, Mining, Rounds, IERC20} from "./helpers/Task16Base.sol";
import {Test} from "forge-std/Test.sol";

/// Local runtime/storage and synthetic owner attestations. No fork or live authorization implied.
contract Task16Handler is Test {
    Mining public immutable miner;
    uint256 public ghostSpent = 0.5 ether;
    uint256 public ghostDispatches = 1;
    uint256 public ghostVolume = 1 ether;
    uint256 public ghostHumanPaid;
    mapping(bytes32 => bool) public seenRequest;
    mapping(bytes32 => bool) public seenBody;

    constructor(Mining m, bytes32 first, bytes32 hash) {
        miner = m;
        seenRequest[first] = true;
        seenBody[hash] = true;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + uint256(raw) % (6 hours + 1));
    }

    function bid(uint8 who) external {
        uint256 price = miner.currentPrice();
        uint256 epoch = miner.epoch();
        vm.prank(address(uint160(101 + who % 2)));
        miner.bid(epoch, price, block.timestamp);
        ghostVolume += price;
    }

    function claim(uint8 who) external {
        vm.startPrank(address(uint160(101 + who % 2)));
        ghostHumanPaid += miner.claimFincr();
        miner.claimImd();
        vm.stopPrank();
    }

    function dispatch(uint8 rawSlot) external {
        uint256 id = (block.timestamp - miner.genesis()) / 1 days;
        if (id >= 3) return;
        bytes memory body = abi.encodePacked(
            '{"objective":"LOCAL ONLY FINANCIER research; NEVER SUBMIT", "intent":"',
            vm.toString(id),
            "-",
            vm.toString(uint256(rawSlot % 3)),
            '"}'
        );
        uint256 held = miner.imd().balanceOf(address(miner));
        uint256 work = miner.workBudget();
        uint256 outgoing = miner.totalOutgoingCredits();
        uint256 buyback = miner.buybackBudget();
        uint256 lp = miner.liquidityBudget();
        uint256 ops = miner.operationsBudget();
        vm.prank(address(702));
        (bool ok, bytes memory result) = address(miner).call(abi.encodeCall(miner.dispatchWork, (id, body)));
        if (ok) {
            bytes32 request = abi.decode(result, (bytes32));
            bytes32 hash = keccak256(body);
            assertFalse(seenRequest[request]);
            assertFalse(seenBody[hash]);
            seenRequest[request] = true;
            seenBody[hash] = true;
            ghostSpent += 0.5 ether;
            ghostDispatches++;
            assertEq(miner.workBudget(), work - 0.5 ether);
            assertEq(miner.imd().balanceOf(address(miner)), held - 0.5 ether);
        } else {
            assertEq(miner.workBudget(), work);
            assertEq(miner.imd().balanceOf(address(miner)), held);
        }
        assertEq(miner.totalOutgoingCredits(), outgoing);
        assertEq(miner.buybackBudget(), buyback);
        assertEq(miner.liquidityBudget(), lp);
        assertEq(miner.operationsBudget(), ops);
    }
}

contract Task16InvariantTest is Task16Base {
    Task16Handler handler;

    function setUp() public override {
        super.setUp();
        start();
        bytes32 first = dispatch(0, 0);
        vm.warp(block.timestamp + 2);
        Rounds.Admission memory a = admission(first, 0, 0);
        vm.prank(SETTLER);
        rounds.bindJob(0, a);
        vm.warp(rounds.context(0).end);
        settleEqual(a.jobId);
        handler = new Task16Handler(miner, first, keccak256(body(0, 0)));
        // Seed a second paid request to avoid a purely no-funds/no-dispatch random campaign.
        handler.bid(1);
        handler.bid(0);
        handler.bid(1); // Fixed openings need three 5% work additions after the first job.
        handler.dispatch(0);
        assertEq(handler.ghostDispatches(), 2);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.bid.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.dispatch.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantActualWorkAndAllImdBucketsRemainSolvent() public view {
        assertGt(handler.ghostDispatches(), 0);
        assertEq(miner.totalWorkSpent(), handler.ghostSpent());
        assertEq(imd.balanceOf(PAYEE), handler.ghostSpent());
        assertEq(miner.totalBidVolume(), handler.ghostVolume());
        assertSolvent();
    }

    function invariantFiniteAgentAndIndependentFinancierConservation() public view {
        assertGt(miner.totalAgentPaid(), 0);
        assertLe(rounds.totalPaid(), rounds.totalAllocated());
        assertEq(rounds.totalPaid(), miner.totalAgentPaid());
        assertEq(rounds.totalAllocated() + rounds.totalQuarantined(), rounds.totalFinalizedBudget());
        assertLe(rounds.totalFinalizedBudget(), miner.agentReserved());
        assertEq(miner.totalFincrPaid(), handler.ghostHumanPaid());
        assertEq(token.balanceOf(address(miner)), miner.requiredFincrCustody());
        assertEq(
            token.balanceOf(address(miner)),
            miner.financierLiability() + miner.agentUnpaid() + miner.unscheduledReserve()
        );
    }

    function afterInvariant() public {
        vm.warp(block.timestamp + 366 days);
        handler.claim(0);
        handler.claim(1);
        assertEq(miner.totalFincrPaid(), 3.2e26);
        assertEq(miner.financierLiability(), 0);
        assertSolvent();
    }
}
