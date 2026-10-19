// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../src/FINCR.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {FinancierMiningWithMarket} from "../src/FinancierMiningWithMarket.sol";
import {FounderFundedMining} from "../src/FounderFundedMining.sol";
import {RobinhoodJobController} from "../src/RobinhoodJobController.sol";
import {AttestedAgentRounds} from "../src/AttestedAgentRounds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface INativeIntakeControl {
    function setPrice(bytes32, address, uint256) external;
    function setPayTo(address) external;
    function setWriter(address) external;
    function setCallbackGas(uint64) external;
    function complete(bytes32, uint8, bytes32, string calldata, bytes calldata) external;
}

/// Actual service runtime, SYNTHETIC local constructor/storage and token deployment, never production proof.
contract Task27BGenesisTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant GUARD = 0x19Bec7C2E1b2aadAf67b259744751a9960d66000;
    address constant ALICE = address(101);
    address constant BOB = address(102);
    FINCR token;
    FounderFundedMining miner;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(1_800_000_000);
        vm.etch(IMD, vm.parseBytes(vm.readLine("test/fixtures/task16/imd-runtime.hex")));
        vm.etch(INTAKE, vm.parseBytes(vm.readLine("test/fixtures/task16/intake-runtime.hex")));
        vm.etch(MANAGER, vm.parseBytes(vm.readLine("test/fixtures/task23/manager-runtime.hex")));
        vm.etch(GUARD, vm.parseBytes(vm.readLine("test/fixtures/task23/guard-runtime.hex")));
        vm.store(IMD, 0, bytes32(uint256(uint160(address(this)))));
        (bool ok,) = IMD.call(abi.encodeWithSignature("enableTransfers()")); require(ok);
        vm.store(INTAKE, 0, bytes32(uint256(uint160(address(this)))));
        INativeIntakeControl(INTAKE).setPrice("job.open@job-1", IMD, 0.5 ether);
        INativeIntakeControl(INTAKE).setPayTo(address(800));
        INativeIntakeControl(INTAKE).setWriter(address(this));
        INativeIntakeControl(INTAKE).setCallbackGas(200_000);
        token = new FINCR(1e27);
        miner = new FounderFundedMining(config());
        deal(IMD, ALICE, 100 ether); deal(IMD, BOB, 100 ether);
        vm.prank(ALICE); IERC20(IMD).approve(address(miner), type(uint256).max);
        vm.prank(BOB); IERC20(IMD).approve(address(miner), type(uint256).max);
    }

    function config() internal view returns (FinancierMiningWithMarket.Config memory c) {
        c = FinancierMiningWithMarket.Config(address(token), IMD, 1e27, 10 ether, 0.5 ether,
            address(this), address(105), address(0), keccak256("SYNTHETIC candidate policy"), 1 days, 1 days, 1 hours, 0.1 ether);
    }
    function start() internal {
        token.transfer(address(miner), 4e26);
        miner.arm();
        vm.prank(ALICE); miner.bid(0, 10 ether, block.timestamp);
    }

    function testNoPreActivationBidOrEmissionAndExplicitActivation() public {
        vm.expectRevert(FinancierMining.NotArmed.selector); vm.prank(ALICE); miner.bid(0, 10 ether, block.timestamp);
        token.transfer(address(miner), 4e26);
        vm.warp(block.timestamp + 10 minutes);
        assertFalse(miner.armed()); assertEq(miner.epoch(), 0); assertEq(miner.agentReserved(), 0);
        miner.arm(); assertEq(miner.auctionStart(), block.timestamp); assertEq(miner.genesis(), 0);
        assertEq(miner.currentPrice(), 10 ether);
        vm.warp(block.timestamp + 1800); assertEq(miner.currentPrice(), 5.25 ether);
        vm.warp(block.timestamp + 1800); assertEq(miner.currentPrice(), 0.5 ether);
        vm.prank(ALICE); miner.bid(0, 0.5 ether, block.timestamp);
        uint256 g = miner.genesis(); assertEq(g, block.timestamp); assertEq(miner.currentPrice(), 10 ether);
        vm.warp(block.timestamp + 3600); vm.prank(BOB); miner.bid(1, 0.5 ether, block.timestamp);
        assertEq(miner.genesis(), g); assertEq(miner.currentPrice(), 10 ether);
        vm.expectRevert(FinancierMining.AlreadyArmed.selector); miner.arm();
    }

    function testShortFundingAndFailedActivationPreserveBalancesThenCanRetry() public {
        token.transfer(address(miner), 4e26 - 1);
        vm.expectRevert(FinancierMining.Unfunded.selector); miner.arm();
        assertFalse(miner.armed()); assertEq(miner.auctionStart(), 0); assertEq(token.balanceOf(address(miner)), 4e26 - 1);
        token.transfer(address(miner), 1); miner.arm(); assertTrue(miner.armed());
    }

    function testAllowanceDoesNotFundOrActivateAndWrongChainCannotDeploy() public {
        token.approve(address(miner), 4e26);
        vm.expectRevert(FinancierMining.Unfunded.selector); miner.arm();
        assertEq(token.balanceOf(address(miner)), 0); assertEq(miner.genesis(), 0);
        FinancierMiningWithMarket.Config memory c = config();
        vm.chainId(1); vm.expectRevert(); new FounderFundedMining(c);
        vm.chainId(4663); token.transfer(address(miner), 4e26); miner.arm();
        assertEq(token.allowance(address(miner), address(this)), 0);
    }

    function testMultipleNativeJobsHaveDistinctBindingButNoRecipientFinalization() public {
        start(); RobinhoodJobController jobs = miner.jobs();
        vm.prank(ALICE); bytes32 a = jobs.commission(0, 0);
        vm.prank(ALICE); bytes32 b = jobs.commission(0, 1);
        assertTrue(a != b); assertEq(miner.totalWorkSpent(), 1 ether);
        bytes32 hash = keccak256("SYNTHETIC manipulated duplicate-agent payout list");
        INativeIntakeControl(INTAKE).complete(a, 0, hash, "uri", abi.encode(a, hash, "uri"));
        INativeIntakeControl(INTAKE).complete(b, 0, hash, "uri", abi.encode(b, hash, "uri"));
        (bool finalized,,,,,) = miner.agentRounds().rounds(0);
        assertFalse(finalized); assertEq(miner.totalAgentPaid(), 0);
        (bool ok,) = address(jobs).call(abi.encodeWithSignature("finalizeRound(uint256,bytes32)", 0, hash));
        assertFalse(ok);
    }

    function testWrongAuthorityWrongAssetWrongChainAndCodeDrift() public {
        FINCR other = new FINCR(1e27); other.transfer(address(miner), 4e26);
        vm.expectRevert(FinancierMining.Unfunded.selector); miner.arm();
        token.transfer(address(miner), 4e26);
        vm.expectRevert(FinancierMining.Unauthorized.selector); vm.prank(ALICE); miner.arm();
        vm.chainId(1); vm.expectRevert(FounderFundedMining.InvalidCanonicalConfiguration.selector); miner.arm();
        vm.chainId(4663); bytes memory code = address(token).code; vm.etch(address(token), hex"00");
        vm.expectRevert(FounderFundedMining.InvalidCanonicalConfiguration.selector); miner.arm();
        vm.etch(address(token), code); miner.arm();
    }

    function testConfigurationCannotSelectSpoofTokenOrOperationsAsFounderOrPublisher() public {
        FinancierMiningWithMarket.Config memory c = config();
        c.fincr = IMD; vm.expectRevert(); new FounderFundedMining(c);
        c = config(); c.initializer = ALICE; vm.expectRevert(FounderFundedMining.InvalidCanonicalConfiguration.selector); new FounderFundedMining(c);
        c = config(); c.authority = ALICE; vm.expectRevert(FounderFundedMining.InvalidCanonicalConfiguration.selector); new FounderFundedMining(c);
        c = config(); c.quote = 1 ether; vm.expectRevert(FounderFundedMining.InvalidCanonicalConfiguration.selector); new FounderFundedMining(c);
        c = config(); c.operations = c.initializer; vm.expectRevert(); new FounderFundedMining(c);
        assertLe(type(FounderFundedMining).creationCode.length + abi.encode(config()).length, 49152);
    }

    function testExcessDuplicateAndUnsolicitedTransfersDoNotExpandReserveOrGrantControl() public {
        token.transfer(address(miner), 2e26); token.transfer(address(miner), 2e26);
        token.transfer(ALICE, 1); vm.prank(ALICE); token.transfer(address(miner), 1);
        miner.arm(); assertEq(miner.miningReserve(), 4e26);
        assertEq(token.balanceOf(address(miner)), 4e26 + 1);
        (bool ok,) = address(miner).call(abi.encodeWithSignature("withdraw(address,uint256)", ALICE, 4e26)); assertFalse(ok);
        (ok,) = address(miner).call(abi.encodeWithSignature("approve(address,uint256)", ALICE, 4e26)); assertFalse(ok);
        assertEq(token.allowance(address(miner), address(this)), 0);
    }

    function testNativeCompletionAfterTakeoverCannotAuthorizeAnyAgentPayout() public {
        start();
        RobinhoodJobController jobs = miner.jobs();
        vm.prank(ALICE); bytes32 request = jobs.commission(0, 0);
        (uint256 period, bytes32 bodyHash,) = miner.workRequests(request);
        assertEq(period, 1); assertEq(bodyHash, keccak256(jobs.body(0, 0)));
        assertEq(IERC20(IMD).allowance(address(miner), INTAKE), 0);
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        vm.warp(block.timestamp + 10); vm.prank(BOB); miner.bid(1, 10 ether, block.timestamp);
        bytes32 result = keccak256("SYNTHETIC incomplete result: not an agent payout manifest");
        string memory uri = "https://api.imd.fun/intake-results/SYNTHETIC";
        INativeIntakeControl(INTAKE).complete(request, 0, result, uri, abi.encode(request, result, uri));
        (bool recorded, uint8 status, bytes32 actual,) = miner.completions(request);
        assertTrue(recorded); assertEq(status, 0); assertEq(actual, result);
        assertEq(miner.totalAgentPaid(), 0); assertEq(miner.agentRounds().totalAllocated(), 0);
        vm.prank(ALICE); assertGt(miner.claimFincr(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid(), 4e26);
        vm.warp(miner.agentRounds().context(0).deadline + 1); miner.agentRounds().expire(0);
        assertEq(miner.agentRounds().totalQuarantined(), miner.agentAllocation(0, 1 days));
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testOfficialSuccessHashOfEmptyWorkNeverAuthorizesAgentRewards() public {
        start();
        RobinhoodJobController jobs = miner.jobs();
        AttestedAgentRounds rounds = miner.agentRounds();
        vm.prank(ALICE); bytes32 id = jobs.commission(0, 0);
        // SYNTHETIC writer success with zero artifact bytes. A nonzero hash and URI
        // authenticate neither nonempty work nor its author/payout wallet.
        bytes32 emptyArtifact = keccak256(bytes(""));
        INativeIntakeControl(INTAKE).complete(
            id, 0, emptyArtifact, "uri", abi.encode(id, emptyArtifact, "uri")
        );
        (bool recorded, uint8 status, bytes32 result,) = miner.completions(id);
        assertTrue(recorded); assertEq(status, 0); assertEq(result, emptyArtifact);
        vm.expectRevert(AttestedAgentRounds.NoClaim.selector); vm.prank(ALICE); rounds.claim(0);
        assertEq(miner.totalAgentPaid(), 0);
        assertEq(rounds.totalAllocated(), 0);
        vm.warp(rounds.context(0).deadline + 1);
        rounds.expire(0);
        assertEq(rounds.totalQuarantined(), miner.agentAllocation(0, 1 days));
        vm.prank(ALICE); assertGt(miner.claimFincr(), 0);
    }

    function testMaliciousUnboundDuplicateCallbackAndReplayReject() public {
        start(); RobinhoodJobController jobs = miner.jobs(); vm.prank(ALICE); bytes32 id = jobs.commission(0, 1);
        bytes32 result = keccak256("SYNTHETIC result");
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector); miner.onResult(id, result, "uri");
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector); vm.prank(INTAKE); miner.onResult(id, result, "uri");
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector); vm.prank(INTAKE); miner.onResult(bytes32(uint256(1)), result, "uri");
        INativeIntakeControl(INTAKE).complete(id, 0, result, "uri", abi.encode(id, result, "uri"));
        vm.expectRevert(FounderFundedMining.InvalidCompletion.selector); vm.prank(INTAKE); miner.onResult(id, result, "uri");
        vm.expectRevert(); INativeIntakeControl(INTAKE).complete(id, 0, result, "uri", abi.encode(id, result, "uri"));
        vm.expectRevert(); vm.prank(ALICE); jobs.commission(0, 1);
    }

    function testJobFailureAndUnauthorizedScopeCannotBlockClaims() public {
        start();
        RobinhoodJobController jobs = miner.jobs();
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector); jobs.commission(0, 0);
        vm.expectRevert(); vm.prank(ALICE); jobs.commission(0, 4);
        vm.prank(ALICE); bytes32 id = jobs.commission(0, 2);
        INativeIntakeControl(INTAKE).complete(id, 2, 0, "", abi.encode(id, uint8(2), bytes32("failed"), uint16(0), uint16(0), bytes("")));
        (bool recorded, uint8 status,,) = miner.completions(id); assertTrue(recorded); assertEq(status, 2);
        vm.warp(block.timestamp + 100); vm.prank(ALICE); assertGt(miner.claimFincr(), 0);
        assertEq(miner.totalAgentPaid(), 0);
    }

    function testFuzzFundingHasFixedBoundedRewards(uint96 extra) public {
        extra = uint96(bound(extra, 0, 1e20));
        token.transfer(address(miner), 4e26 + extra); miner.arm();
        vm.prank(ALICE); miner.bid(0, 10 ether, block.timestamp);
        vm.warp(block.timestamp + 365 days);
        (uint256 gross, uint256 financier, uint256 agents) = miner.cumulativeAt(365 days);
        assertEq(gross, 4e26); assertEq(financier, 3.2e26); assertEq(agents, 0.8e26);
        vm.prank(ALICE); assertEq(miner.claimFincr(), financier);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid(), 4e26 + extra);
    }
}
