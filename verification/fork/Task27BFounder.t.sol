// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {FounderFundedMining} from "../../src/FounderFundedMining.sol";
import {FinancierMiningWithMarket} from "../../src/FinancierMiningWithMarket.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Market} from "../../src/market/IV4Market.sol";
import {V4AttackActor} from "../../test/helpers/Task23Base.sol";

interface INativeWriter {
    function writer() external view returns (address);
    function complete(bytes32, uint8, bytes32, string calldata, bytes calldata) external;
}

/// Real factory/Intake/IMD/manager runtime and state. LOCAL synthetic FINCR launch and privileged
/// caller impersonation only. Neither a production launch nor an accepted-agent proof is claimed.
contract Task27BFounderForkTest is RobinhoodFactoryForkTest {
    FINCR private token;
    FounderFundedMining private miner;
    function testTask27BTradingAlreadyWorksBeforeReserveFunding() public {
        IProjectFactory.CustomParams memory p = customFincrParams(9_027_101);
        p.contractCreationCodes = new bytes[](0);
        p.contractNames = new bytes32[](0);
        p.expectedContracts = new address[](0);
        vm.prank(FACTORY.deployer());
        (address t,,) = FACTORY.launchCustom(p);
        (IProjectFactory.PoolKey memory key,,,) = FACTORY.positionOf(p.launchNumber);
        assertEq(key.currency0, p.pairedCurrency);
        V4AttackActor buyer = new V4AttackActor(0x8366a39CC670B4001A1121B8F6A443A643e40951,
            IV4Market.PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));
        deal(p.pairedCurrency, address(buyer), 1 ether);
        uint256 reserveStillWithFounder = IERC20(t).balanceOf(address(this));
        buyer.trade(true, 0.01 ether, 4295128740);
        assertGt(IERC20(t).balanceOf(address(buyer)), 0);
        assertGe(reserveStillWithFounder, 4e26);
        assertEq(IERC20(t).balanceOf(address(this)), reserveStillWithFounder);
        assertEq(address(miner), address(0)); // No mining deployment or funding yet.
        emit log_string("LOCAL proof: current approved FINCR trades immediately after official factory launch");
    }
    function testTask27BFounderCustodyToGenesisAndNativeCompletion() public {
        {
        IProjectFactory.CustomParams memory p = customFincrParams(9_027_001);
        p.contractCreationCodes = new bytes[](0);
        p.contractNames = new bytes32[](0);
        p.expectedContracts = new address[](0);
        vm.prank(FACTORY.deployer());
        (address t,, address distributor) = FACTORY.launchCustom(p);
        token = FINCR(t);
        assertGe(token.balanceOf(address(this)), 4e26);
        assertEq(token.balanceOf(distributor), 1e26);
        assertEq(p.poolBps, 5000);
        assertEq(token.initialSupply(), 1e27);
        }
        miner = new FounderFundedMining(FinancierMiningWithMarket.Config(
            address(token), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127, 1e27, 10 ether, 0.5 ether,
            address(this), 0x74421cdb9e6ad159358c4af7C59CFAE472A0541e, address(0), keccak256("LOCAL work scope; no positive settlement authority"),
            1 days, 1 days, 1 hours, 0.1 ether));
        assertEq(address(token).codehash, miner.FINCR_HASH());
        vm.warp(block.timestamp + 7 minutes); // Operational target, no on-chain expiry.
        token.transfer(address(miner), 4e26);
        assertFalse(miner.armed()); assertEq(miner.genesis(), 0);
        miner.arm(); assertEq(miner.currentPrice(), 10 ether);
        address imd = miner.WORK_ASSET();
        deal(imd, address(101), 100 ether); deal(imd, address(102), 100 ether);
        vm.prank(address(101)); IERC20(imd).approve(address(miner), type(uint256).max);
        vm.prank(address(102)); IERC20(imd).approve(address(miner), type(uint256).max);
        vm.prank(address(101)); miner.bid(0, 10 ether, block.timestamp);
        uint256 g = miner.genesis();
        assertEq(miner.currentPrice(), 10 ether);
        address jobs = address(miner.jobs());
        vm.prank(address(101));
        (bool ok, bytes memory output) = jobs.call(abi.encodeWithSignature("commission(uint256,uint256)", 0, 0));
        require(ok, "native commission");
        bytes32 id = abi.decode(output, (bytes32));
        assertEq(miner.totalWorkSpent(), 0.5 ether);
        vm.warp(block.timestamp + 100);
        vm.prank(address(102)); miner.bid(1, 10 ether, block.timestamp);
        assertEq(miner.genesis(), g);
        // SYNTHETIC completion only: actual writer authentication and callback EVM path.
        bytes32 result = keccak256("LOCAL missing exhaustive recipient manifest");
        address intake = miner.WORK_INTAKE();
        address writer = INativeWriter(intake).writer();
        vm.prank(writer);
        INativeWriter(intake).complete(id, 0, result, "ipfs://LOCAL/result.json", abi.encode(id, result, "ipfs://LOCAL/result.json"));
        (bool recorded, uint8 status, bytes32 hash,) = miner.completions(id);
        assertTrue(recorded); assertEq(status, 0); assertEq(hash, result);
        assertEq(miner.totalAgentPaid(), 0);
        vm.prank(address(101)); assertGt(miner.claimFincr(), 0);
        assertEq(token.balanceOf(address(miner)) + miner.totalFincrPaid() + miner.totalAgentPaid(), 4e26);
        assertEq(IERC20(imd).balanceOf(address(miner)), miner.imdLiability());
        assertEq(token.totalSupply() + miner.totalFincrBurned(), 1e27);
        vm.warp(miner.agentRounds().context(0).deadline + 1); miner.agentRounds().expire(0);
        assertEq(miner.agentRounds().totalQuarantined(), miner.agentAllocation(0, 1 days));
        emit log_named_address("LOCAL founder-funded miner; NOT production", address(miner));
        emit log_named_uint("Exact mining reserve", miner.miningReserve());
    }
}
