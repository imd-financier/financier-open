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

interface ISeatForkWriter {
    function writer() external view returns (address);
    function complete(bytes32, uint8, bytes32, string calldata, bytes calldata) external;
}

/// Real Robinhood factory/Intake/IMD state. Synthetic LOCAL launch, work and settlement.
/// Writer/attester impersonation stays inside Forge; no production authenticity is asserted.
contract Task30GatewayForkTest is RobinhoodFactoryForkTest {
    PublisherGateway private gateway;
    address private constant founder = 0xbcF19c0821A245383c127570615896Abac9e424F;
    FINCR private token;
    FounderFundedMining private miner;
    RobinhoodJobController private jobs;
    IERC20 private imd;
    address private constant attester = address(700);

    function testTask30GatewayFactoryFundingNativeCallbackAndTwoSeatOwnerPullClaim() public {
        {
            IProjectFactory.CustomParams memory p = customFincrParams(9_027_401);
            p.contractCreationCodes = new bytes[](0);
            p.contractNames = new bytes32[](0);
            p.expectedContracts = new address[](0);
            vm.prank(FACTORY.deployer());
            (address t,, address distributor) = FACTORY.launchCustom(p);
            token = FINCR(t);
            assertGe(token.balanceOf(address(this)), 4e26);
            assertEq(token.balanceOf(distributor), 1e26);
        }
        vm.prank(founder);
        gateway = new PublisherGateway(attester);
        vm.prank(founder);
        jobs = new RobinhoodJobController(address(gateway));
        vm.prank(founder);
        gateway.bindController(jobs, address(jobs).codehash);
        vm.prank(founder);
        gateway.setPaused(false);
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
        vm.prank(founder);
        miner = new FounderFundedMining(config);
        vm.prank(founder);
        jobs.bindMiner(INativeJobMining(address(miner)));
        token.transfer(address(miner), 4e26);
        assertFalse(miner.armed());
        vm.prank(founder);
        miner.arm();
        assertEq(miner.currentPrice(), 10 ether);
        imd = IERC20(miner.WORK_ASSET());
        deal(address(imd), address(101), 100 ether);
        vm.prank(address(101));
        imd.approve(address(miner), type(uint256).max);
        vm.prank(address(101));
        miner.bid(0, 10 ether, block.timestamp);
        vm.prank(address(101));
        bytes32 request = jobs.commission(0, 0);
        bytes32 bodyHash = keccak256(jobs.body(0, 0));
        bytes32 job = keccak256("SYNTHETIC LOCAL FINANCIER UUID");
        vm.prank(attester);
        gateway.bindJob(
            0, Rounds.Admission(request, job, bodyHash, block.timestamp, block.timestamp, keccak256("LOCAL admission"))
        );
        vm.warp(block.timestamp + 100);
        bytes32 result = keccak256("SYNTHETIC nonempty report");
        ISeatForkWriter intake = ISeatForkWriter(miner.WORK_INTAKE());
        address writer = intake.writer();
        vm.prank(writer);
        intake.complete(request, 0, result, "ipfs://LOCAL/report", abi.encode(request, result, "ipfs://LOCAL/report"));
        (bool recorded,,,) = miner.completions(request);
        assertTrue(recorded);
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
        vm.prank(attester);
        gateway.lockSnapshot(0, sn);
        bytes32 commitment = rounds.settlementCommitment(0, a, sn, o);
        vm.prank(attester);
        gateway.finalizeRound(0, a, sn, o, commitment);
        uint256 expected = (miner.agentAllocation(0, 1 days) / 2) * 2;
        vm.prank(address(301));
        assertEq(rounds.claim(0), expected);
        vm.prank(address(101));
        assertGt(miner.claimFincr(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalAgentPaid() + miner.totalFincrPaid(), 4e26);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
    }
}
