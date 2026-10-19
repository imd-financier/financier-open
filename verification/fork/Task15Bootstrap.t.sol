// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {AttestedWorkForkFixture} from "./AttestedWorkForkFixture.sol";
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {RestrictedReserveReceiver as Receiver} from "../../src/RestrictedReserveReceiver.sol";
import {FinancierMiningWithSettlement as Mining} from "../../src/FinancierMiningWithSettlement.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {FINCR} from "../../src/FINCR.sol";
import {IIMDIntake} from "../../src/interfaces/IIMDIntake.sol";
import {IIntakeViews} from "./RobinhoodIntake.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Genuine factory/registry/IMD runtime, synthetic records/settlements, fork impersonation ONLY.
contract Task15BootstrapForkTest is RobinhoodFactoryForkTest, AttestedWorkForkFixture {
    Receiver receiver;
    address constant BOOTSTRAP = address(701);
    address constant SETTLER = address(702);
    bytes32 constant POLICY = keccak256("LOCAL candidate FINANCIER ownership and acceptance policy");
    bytes32 constant REVIEW = keccak256("LOCAL founder reviewed launch/source/50-10-40 record");

    function setUp() public override {
        super.setUp();
        bytes memory tc = abi.encodePacked(type(FINCR).creationCode, abi.encode(uint256(1e27)));
        FINCR probe = new FINCR(1e27);
        Receiver.Pins memory p = Receiver.Pins(
            address(FACTORY),
            FACTORY.registry(),
            FACTORY.deployer(),
            address(FACTORY).codehash,
            FACTORY.registry().codehash,
            keccak256(tc),
            address(probe).codehash,
            keccak256(type(Mining).creationCode),
            type(Mining).creationCode.length
        );
        Receiver.Settings memory s = Receiver.Settings(
            params().pairedCurrency, 1e27, 1 ether, 1 ether, address(105), SETTLER, POLICY, 1 days, 1 days, 1 hours
        );
        receiver = new Receiver(p, s, BOOTSTRAP); // NO launch number/token/miner precommit.
    }

    function prepared(uint64 n) internal view returns (IProjectFactory.CustomParams memory p) {
        p = customFincrParams(n);
        p.remainderTo = address(receiver);
        p.contractCreationCodes = new bytes[](1);
        p.contractNames = new bytes32[](1);
        p.expectedContracts = new address[](1);
        address t = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        p.contractNames[0] = "FinancierMiningWithSettlement";
        p.contractCreationCodes[0] = bytes.concat(type(Mining).creationCode, receiver.minerArguments(t));
        p.expectedContracts[0] = FACTORY.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
    }

    function launch(IProjectFactory.CustomParams memory p) internal returns (FINCR t, Mining m, address d) {
        vm.prank(FACTORY.deployer());
        (address token, address[] memory apps, address distributor) = FACTORY.launchCustom(p);
        return (FINCR(token), Mining(apps[0]), distributor);
    }

    function bootstrap(IProjectFactory.CustomParams memory p) internal {
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(p.launchNumber, p.tokenCreationCode, p.contractCreationCodes[0], REVIEW);
    }

    function testTask15ActualLaunchReserveBidFinancierAndEqualAgentClaims() public {
        IProjectFactory.CustomParams memory p = prepared(9_150_000);
        (FINCR t, Mining m, address d) = launch(p);
        Rounds r = m.agentRounds();
        uint256 held = t.balanceOf(address(receiver));
        uint256 pool = t.balanceOf(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(t.balanceOf(d), 1e26);
        assertEq(pool + held + t.balanceOf(d), 1e27);
        assertGe(held, 4e26);
        assertEq(pool, 5e26 - (held - 4e26));
        bytes32[] memory jobs = new bytes32[](1);
        jobs[0] = keccak256(requestBody());
        vm.prank(SETTLER);
        r.precommitRound(0, jobs, keccak256("LOCAL acceptance specification"));
        uint256 gasBefore = gasleft();
        bootstrap(p);
        emit log_named_uint("Task15 atomic bootstrap execution gas", gasBefore - gasleft());
        assertEq(t.balanceOf(address(m)), 4e26);
        assertEq(t.balanceOf(address(receiver)), held - 4e26);
        assertEq(m.epoch(), 0);
        assertEq(m.genesis(), 0);
        assertTrue(m.armed());
        IERC20 imd = IERC20(p.pairedCurrency);
        deal(address(imd), address(101), 2 ether);
        vm.startPrank(address(101));
        imd.approve(address(m), 1 ether);
        m.bid(0, 1 ether, block.timestamp);
        assertEq(m.claimFincr(), 0);
        vm.stopPrank();
        bytes32 admittedJob = requestAndBind(m);
        vm.warp(r.context(0).end);
        vm.prank(address(101));
        uint256 human = m.claimFincr();
        assertGt(human, 0);
        settleAndClaim(m, admittedJob, 2);
        assertEq(m.totalFincrPaid(), human);
        assertEq(t.balanceOf(address(m)) + m.totalFincrPaid() + m.totalAgentPaid(), 4e26);
        // Automatic outgoing payment against genuine IMD runtime, entirely on the local fork.
        deal(address(imd), address(102), 1 ether);
        uint256 outgoingBefore = imd.balanceOf(address(101));
        vm.startPrank(address(102));
        imd.approve(address(m), 1 ether);
        m.bid(1, 1 ether, block.timestamp);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(101)) - outgoingBefore, 0.8 ether);
        assertEq(m.outgoingCredit(address(101)), 0);
        vm.prank(address(101));
        assertEq(m.claimImd(), 0);
        assertEq(imd.balanceOf(address(m)), m.imdLiability());
        vm.warp(m.genesis() + 366 days);
        vm.prank(address(102));
        m.claimFincr();
        assertEq(m.totalFincrPaid(), 3.2e26);
        emit log_named_uint("Task15 stranded LP rounding base units", held - 4e26);
    }

    function testTask15ActualCompetingLaunchCannotFrontRunSelection() public {
        IProjectFactory.CustomParams memory a = prepared(9_150_100);
        (FINCR ta, Mining ma,) = launch(a);
        IProjectFactory.CustomParams memory b = prepared(9_150_200);
        (FINCR tb, Mining mb,) = launch(b);
        vm.expectRevert(Receiver.Authority.selector);
        receiver.bootstrap(a.launchNumber, a.tokenCreationCode, a.contractCreationCodes[0], REVIEW);
        bootstrap(b);
        assertFalse(ma.armed());
        assertTrue(mb.armed());
        assertGe(ta.balanceOf(address(receiver)), 4e26);
        assertEq(tb.balanceOf(address(mb)), 4e26);
        vm.expectRevert(Receiver.Replay.selector);
        bootstrap(a);
    }

    function testTask15ActualCodeAdaptationAndEveryConstructorChangeFailClosed() public {
        IProjectFactory.CustomParams memory p = prepared(9_150_300);
        (FINCR t, Mining m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        for (uint256 i; i < 12; ++i) {
            bytes memory bad = bytes.concat(p.contractCreationCodes[0]);
            bad[type(Mining).creationCode.length + i * 32 + 31] ^= 0x01;
            vm.expectRevert(Receiver.Creation.selector);
            vm.prank(BOOTSTRAP);
            receiver.bootstrap(p.launchNumber, p.tokenCreationCode, bad, REVIEW);
        }
        bytes memory badPrefix = bytes.concat(p.contractCreationCodes[0]);
        badPrefix[0] ^= 0x01;
        vm.expectRevert(Receiver.Creation.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(p.launchNumber, p.tokenCreationCode, badPrefix, REVIEW);
        assertEq(t.balanceOf(address(receiver)), held);
        assertFalse(receiver.bootstrapped());
        assertFalse(m.armed());
    }

    function testTask15ActualArmFailureRollsBackAndCanRetry() public {
        IProjectFactory.CustomParams memory p = prepared(9_150_400);
        (FINCR t, Mining m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        vm.mockCallRevert(
            address(m), abi.encodeCall(m.arm, ()), abi.encodeWithSignature("Error(string)", "LOCAL FAULT")
        );
        vm.expectRevert(bytes("LOCAL FAULT"));
        bootstrap(p);
        assertFalse(receiver.bootstrapped());
        assertEq(t.balanceOf(address(m)), 0);
        assertEq(t.balanceOf(address(receiver)), held);
        vm.clearMockedCalls();
        bootstrap(p);
        assertTrue(m.armed());
    }

    function testTask15ActualChangedDeploymentCannotBeOverriddenByFounder() public {
        IProjectFactory.CustomParams memory p = prepared(9_150_500);
        // Real factory accepts an altered settlement authority. Receiver must not follow it.
        bytes memory changed = receiver.minerArguments(FACTORY.predictToken(p.launchNumber, p.tokenCreationCode));
        assembly ("memory-safe") {
            mstore(add(changed, 256), 703) // eighth constructor word, not a calldata destination
        }
        p.contractCreationCodes[0] = bytes.concat(type(Mining).creationCode, changed);
        assertAdaptedLaunchStaysLocked(p);
        // Solidity accepts extra init bytes; even this adaptation changes the CREATE2 commitment.
        p = prepared(9_150_600);
        p.contractCreationCodes[0] = bytes.concat(p.contractCreationCodes[0], hex"00");
        assertAdaptedLaunchStaysLocked(p);
        p = prepared(9_150_700);
        (, Mining good,) = launch(p);
        bootstrap(p);
        assertTrue(good.armed()); // failed incompatible launches did not consume selection
    }

    function assertAdaptedLaunchStaysLocked(IProjectFactory.CustomParams memory p) internal {
        p.expectedContracts[0] = FACTORY.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
        (FINCR t, Mining m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        vm.expectRevert(Receiver.Creation.selector);
        bootstrap(p);
        assertEq(t.balanceOf(address(receiver)), held);
        assertEq(t.balanceOf(address(m)), 0);
        assertFalse(m.armed());
        assertFalse(receiver.bootstrapped());
    }
}
