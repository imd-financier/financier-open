// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PublisherGateway} from "../../src/PublisherGateway.sol";
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {FounderFundedMining} from "../../src/FounderFundedMining.sol";
import {RobinhoodJobController, INativeJobMining} from "../../src/RobinhoodJobController.sol";
import {FinancierMiningWithMarket} from "../../src/FinancierMiningWithMarket.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITask33ForkWriter {
    function writer() external view returns (address);
    function complete(bytes32, uint8, bytes32, string calldata, bytes calldata) external;
}

/// Real Robinhood factory/Intake/IMD state. Synthetic LOCAL launch, work and settlement.
/// Writer/attester impersonation stays inside Forge; no production authenticity is asserted.
contract Task33GatewayForkTest is RobinhoodFactoryForkTest {
    PublisherGateway private gateway;
    address private constant founder = 0xbcF19c0821A245383c127570615896Abac9e424F;
    FINCR private token;
    FounderFundedMining private miner;
    RobinhoodJobController private jobs;
    IERC20 private imd;
    address private constant attester = 0x174818c4FEcB65472522Ff8C7677F5A567cB3020;

    uint256 private gasBefore;
    bytes32 private request;
    bytes32 private job;

    function testTask33FullProductionOrderAndNegativeGuards() public {
        deployAndFund();
        bidAndCommission();
        settleAndClaim();
    }

    function deployAndFund() internal {
        {
            IProjectFactory.CustomParams memory p = customFincrParams(9_027_401);
            p.contractCreationCodes = new bytes[](0);
            p.contractNames = new bytes32[](0);
            p.expectedContracts = new address[](0);
            p.remainderTo = founder;
            p.requester = founder;
            vm.prank(FACTORY.deployer());
            (address t,, address distributor) = FACTORY.launchCustom(p);
            token = FINCR(t);
            assertGe(token.balanceOf(founder), 4e26);
            assertEq(token.balanceOf(distributor), 1e26);
        }
        assertEq(address(token).codehash, 0x946270e19519507b25f0e64ba542b050d325476e1a397aadf1f64ea23d16064c);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.decimals(), 18);
        emit log_named_address("LOCAL token", address(token));
        emit log_named_uint("LOCAL founder remainder including pool dust", token.balanceOf(founder));
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        new PublisherGateway(attester);
        gasBefore = gasleft();
        vm.prank(founder);
        gateway = new PublisherGateway(attester);
        emit log_named_uint("LOCAL gateway execution gas", gasBefore-gasleft());
        assertTrue(gateway.paused());
        assertEq(gateway.FOUNDER(), founder);
        assertEq(gateway.operator(), attester);
        emit log_named_address("LOCAL gateway", address(gateway));
        gasBefore = gasleft();
        vm.prank(founder);
        jobs = new RobinhoodJobController(address(gateway));
        emit log_named_uint("LOCAL controller execution gas", gasBefore-gasleft());
        emit log_named_address("LOCAL controller", address(jobs));
        emit log_named_bytes32("LOCAL controller runtime hash", address(jobs).codehash);
        assertEq(jobs.initializer(), founder);
        assertEq(jobs.publisher(), address(gateway));
        assertEq(address(jobs.miner()), address(0));
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(founder);
        gateway.bindController(jobs, bytes32(uint256(1)));
        gasBefore = gasleft();
        vm.prank(founder);
        gateway.bindController(jobs, address(jobs).codehash);
        emit log_named_uint("LOCAL bindGateway execution gas", gasBefore-gasleft());
        vm.expectRevert(PublisherGateway.InvalidConfiguration.selector);
        vm.prank(founder);
        gateway.bindController(jobs, address(jobs).codehash);
        assertTrue(gateway.paused());
        FinancierMiningWithMarket.Config memory config = FinancierMiningWithMarket.Config(
            address(token),
            0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127,
            1e27,
            10 ether,
            0.5 ether,
            founder,
            0x74421cdb9e6ad159358c4af7C59CFAE472A0541e,
            address(jobs),
            jobs.SPECIFICATION(),
            1 days,
            1 days,
            1 hours,
            0.1 ether
        );
        gasBefore = gasleft();
        vm.prank(founder);
        miner = new FounderFundedMining(config);
        emit log_named_uint("LOCAL miner execution gas", gasBefore-gasleft());
        emit log_named_address("LOCAL miner", address(miner));
        emit log_named_address("LOCAL market", address(miner.market()));
        emit log_named_address("LOCAL rounds", address(miner.agentRounds()));
        assertEq(miner.initializer(), founder);
        assertEq(address(miner.jobs()), address(jobs));
        assertEq(miner.agentRounds().settlementAuthority(), address(jobs));
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        jobs.bindMiner(INativeJobMining(address(miner)));
        gasBefore = gasleft();
        vm.prank(founder);
        jobs.bindMiner(INativeJobMining(address(miner)));
        emit log_named_uint("LOCAL bindMiner execution gas", gasBefore-gasleft());
        vm.expectRevert(RobinhoodJobController.InvalidBinding.selector);
        vm.prank(founder);
        jobs.bindMiner(INativeJobMining(address(miner)));
        vm.expectRevert();
        vm.prank(founder);
        miner.arm();
        gasBefore = gasleft();
        vm.prank(founder);
        token.transfer(address(miner), 4e26);
        emit log_named_uint("LOCAL fundReserve execution gas", gasBefore-gasleft());
        assertEq(token.balanceOf(address(miner)), 4e26);
        vm.expectRevert();
        miner.arm();
        assertFalse(miner.armed());
        gasBefore = gasleft();
        vm.prank(founder);
        miner.arm();
        emit log_named_uint("LOCAL arm execution gas", gasBefore-gasleft());
        assertEq(miner.currentPrice(), 10 ether);
        uint256 armedAt = block.timestamp;
        vm.warp(armedAt+1800);
        assertEq(miner.currentPrice(), 5.25 ether);
        vm.warp(armedAt+3600);
        assertEq(miner.currentPrice(), 0.5 ether);
        assertEq(miner.genesis(), 0);
        vm.expectRevert();
        vm.prank(address(999));
        miner.bid(0, 0.5 ether, block.timestamp);
        vm.prank(attester);
        (bool unknown,) = address(gateway).call(hex"deadbeef");
        assertFalse(unknown);
    }

    function bidAndCommission() internal {
        imd = IERC20(miner.WORK_ASSET());
        deal(address(imd), address(101), 100 ether);
        gasBefore = gasleft();
        vm.prank(address(101));
        imd.approve(address(miner), type(uint256).max);
        emit log_named_uint("LOCAL bidderApprove execution gas", gasBefore-gasleft());
        uint256 beforeFloorBid = vm.snapshotState();
        gasBefore = gasleft();
        vm.prank(address(101));
        miner.bid(0, 0.5 ether, block.timestamp);
        emit log_named_uint("LOCAL insufficientBudgetFloorBid execution gas", gasBefore-gasleft());
        assertEq(miner.currentPrice(), 10 ether);
        // 0.5 IMD genesis funds only 0.425 work budget: insufficient for the 0.5 official job.
        vm.expectRevert();
        vm.prank(address(101));
        jobs.commission(0, 0);
        assertTrue(vm.revertToStateAndDelete(beforeFloorBid));
        vm.warp(block.timestamp-189); //3411s after arm: quote0.99875 IMD.
        assertEq(miner.currentPrice(), 0.99875 ether);
        gasBefore = gasleft();
        vm.prank(address(101));
        miner.bid(0, 1 ether, block.timestamp);
        emit log_named_uint("LOCAL genesisBid execution gas", gasBefore-gasleft());
        assertEq(miner.workBudget(), 0.8489375 ether);
        vm.expectRevert(RobinhoodJobController.Unauthorized.selector);
        vm.prank(attester);
        jobs.commission(0, 0);
        gasBefore = gasleft();
        vm.prank(address(101));
        request = jobs.commission(0, 0);
        emit log_named_uint("LOCAL commission execution gas", gasBefore-gasleft());
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        bytes32 bodyHash = keccak256(jobs.body(0, 0));
        job = keccak256("SYNTHETIC LOCAL FINANCIER UUID");
        Rounds.Admission memory admission = Rounds.Admission(request, job, bodyHash, block.timestamp, block.timestamp, keccak256("LOCAL admission"));
        vm.expectRevert(PublisherGateway.Unavailable.selector);
        vm.prank(attester);
        gateway.bindJob(0, admission);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        gateway.setPaused(false);
        vm.prank(founder);
        gateway.setPaused(false);
        gasBefore = gasleft();
        vm.prank(attester);
        gateway.bindJob(
            0, Rounds.Admission(request, job, bodyHash, block.timestamp, block.timestamp, keccak256("LOCAL admission"))
        );
        emit log_named_uint("LOCAL bindJob execution gas", gasBefore-gasleft());
        vm.warp(block.timestamp + 100);
        bytes32 result = keccak256("SYNTHETIC nonempty report");
        ITask33ForkWriter intake = ITask33ForkWriter(miner.WORK_INTAKE());
        address writer = intake.writer();
        vm.prank(writer);
        intake.complete(request, 0, result, "ipfs://LOCAL/report", abi.encode(request, result, "ipfs://LOCAL/report"));
        (bool recorded,,,) = miner.completions(request);
        assertTrue(recorded);
    }

    function settleAndClaim() internal {
        Rounds rounds = miner.agentRounds();
        W.Context memory c = rounds.context(0);
        Rounds.Snapshot memory sn = Rounds.Snapshot(
            26_000_000,
            keccak256("LOCAL header"),
            c.end - 900,
            keccak256("LOCAL owner evidence"),
            keccak256("LOCAL complete work evidence")
        );
        W.Contribution[] memory a = new W.Contribution[](2);
        Rounds.OwnerEvidence[] memory o = new Rounds.OwnerEvidence[](2);
        for (uint256 i; i < 2; ++i) {
            a[i] = W.Contribution(
                1,
                rounds.IDENTITY_REGISTRY(),
                51_000 + i,
                address(301),
                address(301),
                job,
                keccak256(abi.encode("LOCAL receipt", i)),
                keccak256(abi.encode("LOCAL submission", i)),
                keccak256("LOCAL identical nonempty artifact for two distinct accepted agents"),
                block.timestamp,
                sn.timestamp,
                c.deadline
            );
            o[i] = Rounds.OwnerEvidence(100 + i, false, 0, 0, block.timestamp - 1);
        }
        vm.warp(c.end);
        vm.expectRevert(PublisherGateway.Unauthorized.selector);
        gateway.lockSnapshot(0, sn);
        gasBefore = gasleft();
        vm.prank(attester);
        gateway.lockSnapshot(0, sn);
        emit log_named_uint("LOCAL lockSnapshot execution gas", gasBefore-gasleft());
        bytes32 commitment = rounds.settlementCommitment(0, a, sn, o);
        vm.expectRevert();
        vm.prank(attester);
        gateway.finalizeRound(0, a, sn, o, bytes32(uint256(1)));
        uint256 restore = vm.snapshotState();
        a[1].agentId = a[0].agentId;
        bytes32 duplicateCommitment = rounds.settlementCommitment(0,a,sn,o);
        vm.expectRevert();
        vm.prank(attester);
        gateway.finalizeRound(0, a, sn, o, duplicateCommitment);
        assertTrue(vm.revertToStateAndDelete(restore));
        a[1].agentId = 51_001;
        gasBefore = gasleft();
        vm.prank(attester);
        gateway.finalizeRound(0, a, sn, o, commitment);
        emit log_named_uint("LOCAL finalizeRound execution gas", gasBefore-gasleft());
        uint256 expected = (miner.agentAllocation(0, 1 days) / 2) * 2;
        assertEq(rounds.claimable(0,address(301)), expected);
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(address(302));
        rounds.claim(0);
        gasBefore = gasleft();
        vm.prank(address(301));
        assertEq(rounds.claim(0), expected);
        emit log_named_uint("LOCAL agentClaim execution gas", gasBefore-gasleft());
        vm.expectRevert(Rounds.NoClaim.selector);
        vm.prank(address(301));
        rounds.claim(0);
        gasBefore = gasleft();
        vm.prank(address(101));
        assertGt(miner.claimFincr(), 0);
        emit log_named_uint("LOCAL financierClaim execution gas", gasBefore-gasleft());
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid() + miner.totalFincrPaid(), 4e26);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
    }
}
