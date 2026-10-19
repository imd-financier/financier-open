// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../../src/FINCR.sol";
import {FinancierMiningWithSettlement as Mining} from "../../src/FinancierMiningWithSettlement.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface TokenControl {
    function enableTransfers() external;
}

interface IntakeControl {
    function setPrice(bytes32, address, uint256) external;
    function setPayTo(address) external;
    function nonce() external view returns (uint256);
    function requests(bytes32) external view returns (address, address, bytes4, bool);
    function failureSelectorOf(bytes32) external view returns (bytes4);
}

/// Exact provider-observed runtime, but GENERATED storage/owner/work identities in a local EVM.
/// Full factory + actual storage compatibility is separately tested on the Robinhood fork.
abstract contract Task16Base is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant SETTLER = address(702);
    address constant ALICE = address(101);
    address constant BOB = address(102);
    address constant PAYEE = address(800);
    uint256 constant RESERVE = 4e26;
    FINCR token;
    Mining miner;
    Rounds rounds;
    IERC20 imd = IERC20(IMD);
    IntakeControl intake = IntakeControl(INTAKE);

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_000_000);
        vm.etch(IMD, vm.parseBytes(vm.readLine("test/fixtures/task16/imd-runtime.hex")));
        vm.etch(INTAKE, vm.parseBytes(vm.readLine("test/fixtures/task16/intake-runtime.hex")));
        vm.store(IMD, bytes32(0), bytes32(uint256(uint160(address(this)))));
        TokenControl(IMD).enableTransfers(); // Local synthetic constructor/admin state only.
        // Ownable slot zero in the observed nonproxy runtime. NOT a real permission change.
        vm.store(INTAKE, bytes32(0), bytes32(uint256(uint160(address(this)))));
        intake.setPayTo(PAYEE);
        intake.setPrice("job.open@job-1", IMD, 0.5 ether);
        token = new FINCR(1e27);
        miner = makeMiner(1 ether);
        rounds = miner.agentRounds();
        token.transfer(address(miner), RESERVE);
        miner.arm();
        deal(IMD, ALICE, 1e60);
        deal(IMD, BOB, 1e60);
        vm.prank(ALICE);
        imd.approve(address(miner), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(miner), type(uint256).max);
    }

    function makeMiner(uint256 quote) internal returns (Mining) {
        return new Mining(
            address(token),
            IMD,
            1e27,
            quote,
            quote,
            address(this),
            address(105),
            SETTLER,
            keccak256("LOCAL CANDIDATE FINANCIER policy / exact immutable callback-free Intake envelope"),
            1 days,
            1 days,
            1 hours
        );
    }

    function body(uint256 id, uint256 slot) public pure returns (bytes memory) {
        return abi.encodePacked(
            '{"objective":"LOCAL ONLY FINANCIER research; NEVER SUBMIT", "intent":"',
            vm.toString(id),
            "-",
            vm.toString(slot),
            '"}'
        ); // Exact local JSON, not service-admitted input.
    }

    function scope(uint256 id) internal {
        bytes32[] memory hashes = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            hashes[i] = keccak256(body(id, i));
        }
        vm.prank(SETTLER);
        rounds.precommitRound(id, hashes, keccak256("LOCAL published FINANCIER work/acceptance/request specification"));
    }

    function start() internal {
        scope(0);
        scope(1);
        scope(2);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
    }

    function dispatch(uint256 id, uint256 slot) internal returns (bytes32 request) {
        bytes memory b = body(id, slot);
        vm.prank(SETTLER);
        return miner.dispatchWork(id, b);
    }

    function admission(bytes32 request, uint256 id, uint256 slot) internal view returns (Rounds.Admission memory a) {
        (,, uint256 at) = miner.workRequests(request);
        return Rounds.Admission(
            request,
            keccak256(abi.encode("SIMULATED backend UUID", request)),
            keccak256(body(id, slot)),
            at,
            block.timestamp,
            keccak256("MOCK admission/empty submissions evidence")
        );
    }

    function assertSolvent() internal view {
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(miner.totalBidVolume(), miner.totalImdPaid() + miner.imdLiability());
        assertEq(
            miner.imdLiability(),
            miner.totalOutgoingCredits() + miner.workBudget() + miner.buybackBudget() + miner.liquidityBudget()
                + miner.operationsBudget()
        );
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), RESERVE);
        assertEq(imd.allowance(address(miner), INTAKE), 0);
    }

    function settleEqual(bytes32 job) internal {
        W.Context memory c = rounds.context(0);
        W.Contribution[] memory accepted = new W.Contribution[](2);
        Rounds.OwnerEvidence[] memory owners = new Rounds.OwnerEvidence[](2);
        Rounds.Snapshot memory snap = Rounds.Snapshot(
            123,
            keccak256("MOCK block"),
            c.end - 60,
            keccak256("MOCK owners"),
            keccak256("MOCK complete useful accepted set")
        );
        uint256 boundAt = rounds.jobBoundAt(job);
        for (uint256 i; i < 2; ++i) {
            address who = address(uint160(300 + i));
            accepted[i] = W.Contribution(
                1,
                rounds.IDENTITY_REGISTRY(),
                52643 + i,
                who,
                who,
                job,
                keccak256(abi.encode("receipt", i)),
                keccak256(abi.encode("submission", i)),
                keccak256(abi.encode("artifact", i)),
                boundAt + 2,
                snap.timestamp,
                c.deadline
            );
            owners[i] = Rounds.OwnerEvidence(472 + i, false, 0, 0, boundAt + 1);
        }
        bytes32 digest = rounds.settlementCommitment(0, accepted, snap, owners);
        vm.prank(SETTLER);
        rounds.finalize(0, accepted, snap, owners, digest);
        uint256 share = miner.agentAllocation(0, 1 days) / 2;
        for (uint256 i; i < 2; ++i) {
            vm.prank(accepted[i].beneficiary);
            assertEq(rounds.claim(0), share);
        }
    }
}
