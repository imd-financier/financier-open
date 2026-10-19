// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {RobinhoodFactoryForkTest} from "./RobinhoodFactory.t.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {IIMDLaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";
import {FinancierMiningWithAgents} from "../../src/FinancierMiningWithAgents.sol";
import {FinancierMining} from "../../src/FinancierMining.sol";
import {UnavailableWorkVerifier} from "../../src/UnavailableWorkVerifier.sol";
import {FINCR} from "../../src/FINCR.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsolatedReserveReceiver as Receiver} from "../task8/IsolatedReserveReceiver.sol";

/// Keyless fork ONLY. Inherited tests deliberately rerun the original real-factory regressions.
/// Factory deployer impersonation and synthetic records do NOT prove official source admission.
contract Task8ReceiverForkTest is RobinhoodFactoryForkTest {
    Receiver receiver;
    UnavailableWorkVerifier verifier;
    Receiver.Pins pins;
    Receiver.Settings settings;
    bytes tokenInit;

    function setUp() public override {
        super.setUp();
        // Reject-all is a LOCAL stand-in, never a production deployment recommendation.
        verifier = new UnavailableWorkVerifier();
        tokenInit = abi.encodePacked(type(FINCR).creationCode, abi.encode(uint256(1e27)));
        FINCR runtimeProbe = new FINCR(1e27);
        pins = Receiver.Pins(
            address(FACTORY),
            FACTORY.registry(),
            FACTORY.deployer(),
            address(FACTORY).codehash,
            FACTORY.registry().codehash,
            keccak256(tokenInit),
            address(runtimeProbe).codehash,
            keccak256(type(FinancierMiningWithAgents).creationCode),
            type(FinancierMiningWithAgents).creationCode.length
        );
        settings = Receiver.Settings(
            params().pairedCurrency,
            1e27,
            1 ether,
            1 ether,
            address(105),
            address(verifier),
            keccak256("LOCAL POLICY ONLY"),
            1 days,
            1 days,
            1 hours
        );
        receiver = new Receiver(pins, settings); // No number or future token/miner address here.
    }

    function prepared(uint64 number) internal view returns (IProjectFactory.CustomParams memory p) {
        p = customFincrParams(number);
        p.remainderTo = address(receiver);
        p.contractCreationCodes = new bytes[](1);
        p.contractNames = new bytes32[](1);
        p.expectedContracts = new address[](1);
        p.contractNames[0] = "FinancierMiningWithAgents";
        address token = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        p.contractCreationCodes[0] =
            bytes.concat(type(FinancierMiningWithAgents).creationCode, receiver.minerArguments(token));
        p.expectedContracts[0] = FACTORY.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
    }

    function launch(IProjectFactory.CustomParams memory p)
        internal
        returns (FINCR t, FinancierMiningWithAgents m, address distributor)
    {
        vm.prank(FACTORY.deployer());
        (address token, address[] memory apps, address d) = FACTORY.launchCustom(p);
        return (FINCR(token), FinancierMiningWithAgents(apps[0]), d);
    }

    function forward(IProjectFactory.CustomParams memory p) internal {
        receiver.forward(p.launchNumber, p.tokenCreationCode, p.contractCreationCodes[0]);
    }

    function unchanged(FINCR t, FinancierMiningWithAgents m, uint256 held) internal view {
        assertEq(t.balanceOf(address(receiver)), held);
        assertEq(t.balanceOf(address(m)), 0);
        assertFalse(receiver.forwarded(address(t)));
        assertFalse(m.armed());
    }

    function testTask8UnknownNumberExactFundingClaimsAndNoHeadStart() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_000);
        vm.warp(block.timestamp + 1 hours);
        (FINCR t, FinancierMiningWithAgents m, address d) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        uint256 pool = t.balanceOf(0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(t.balanceOf(d), 1e26);
        assertEq(pool + held + t.balanceOf(d), 1e27);
        assertGe(held, 4e26);
        emit log_named_uint("LP rounding stranded (base units)", held - 4e26);
        assertEq(pool, 5e26 - (held - 4e26));
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        m.arm();
        vm.warp(block.timestamp + 1 days);
        uint256 gasBefore = gasleft();
        vm.prank(address(888));
        forward(p);
        emit log_named_uint("receiver forward execution gas", gasBefore - gasleft());
        assertEq(t.balanceOf(address(m)), 4e26);
        assertEq(t.balanceOf(address(receiver)), held - 4e26);
        assertTrue(m.armed());
        assertEq(m.genesis(), 0);
        assertEq(m.epoch(), 0);
        vm.warp(block.timestamp + 3 days);
        IERC20 imd = IERC20(p.pairedCurrency);
        deal(address(imd), address(101), 2 ether);
        vm.startPrank(address(101));
        imd.approve(address(m), 2 ether);
        m.bid(0, 1 ether, block.timestamp);
        uint256 genesis = m.genesis();
        assertEq(genesis, block.timestamp);
        assertEq(m.claimFincr(), 0);
        vm.warp(genesis + 366 days);
        m.claimFincr();
        vm.stopPrank();
        assertEq(m.totalFincrPaid(), 3.2e26);
        assertEq(m.totalAgentPaid(), 0);
        assertEq(t.balanceOf(address(m)), 8e25);
        m.agentRounds().expire(0);
        assertEq(t.balanceOf(address(m)), 8e25);
    }

    function testTask8ActualTransferPrecedesRegistryAndGuardIsPoolHook() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_200);
        vm.recordLogs();
        (FINCR t,,) = launch(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 remainderIndex = type(uint256).max;
        uint256 registryIndex = type(uint256).max;
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(t) && logs[i].topics[0] == transferTopic
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(receiver))))
            ) remainderIndex = i;
            if (logs[i].emitter == FACTORY.registry() && registryIndex == type(uint256).max) registryIndex = i;
        }
        assertLt(remainderIndex, registryIndex);
        assertLt(registryIndex, logs.length);
        (IProjectFactory.PoolKey memory key,,,) = FACTORY.positionOf(p.launchNumber);
        assertEq(key.hooks, 0x19Bec7C2E1b2aadAf67b259744751a9960d66000);
        assertEq(key.fee, 12500);
        forward(p);
    }

    function testTask8DeployedCounterfeitGetterMinerCannotReceive() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_300);
        address token = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        p.contractCreationCodes[0] =
            abi.encodePacked(type(CounterfeitGetterMiner).creationCode, abi.encode(token, address(receiver)));
        p.expectedContracts[0] = FACTORY.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
        vm.prank(FACTORY.deployer());
        (address deployed, address[] memory apps,) = FACTORY.launchCustom(p);
        assertEq(CounterfeitGetterMiner(apps[0]).fincr(), deployed);
        vm.expectRevert(Receiver.Creation.selector);
        forward(p);
        assertEq(FINCR(deployed).balanceOf(apps[0]), 0);
        assertFalse(receiver.forwarded(deployed));
        assertGe(FINCR(deployed).balanceOf(address(receiver)), 4e26);
    }

    function testTask8ReentrantTransferImplementationCannotPassCodePin() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_400);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        // Fault injection: approved FINCR has no callbacks. This hostile replacement
        // cannot reach transfer at all. No claim of a real mutable FINCR runtime.
        ReentrantTransfer attacker = new ReentrantTransfer();
        vm.etch(address(t), address(attacker).code);
        vm.expectRevert(Receiver.Target.selector);
        forward(p);
        assertFalse(receiver.forwarded(address(t)));
        assertFalse(m.armed());
        emit log_named_uint("reserve held before impossible runtime injection", held);
    }

    function testTask8EarlyIdenticalLaunchCannotConsumeLaterToken() public {
        IProjectFactory.CustomParams memory a = prepared(9_100_100);
        (FINCR ta, FinancierMiningWithAgents ma,) = launch(a);
        // Privileged deployer can put arbitrary source assertions in the official registry.
        IProjectFactory.CustomParams memory b = prepared(9_100_200);
        b.record.sourceCommit = keccak256("DIFFERENT SYNTHETIC SOURCE");
        b.record.attestationHash = keccak256("NOT OFFICIAL");
        (FINCR tb, FinancierMiningWithAgents mb,) = launch(b);
        uint256 heldB = tb.balanceOf(address(receiver));
        forward(a);
        assertEq(tb.balanceOf(address(receiver)), heldB);
        assertFalse(mb.armed());
        forward(b);
        assertEq(ta.balanceOf(address(ma)), 4e26);
        assertEq(tb.balanceOf(address(mb)), 4e26);
        vm.expectRevert(Receiver.Replay.selector);
        forward(a);
        // Both matching launches succeed. This explicitly DISPROVES canonical-launch selection.
    }

    function testTask8MissingRecordAndCrossLaunchSubstitution() public {
        IProjectFactory.CustomParams memory a = prepared(9_100_300);
        vm.expectRevert(Receiver.Record.selector);
        forward(a);
        (FINCR t, FinancierMiningWithAgents m,) = launch(a);
        IProjectFactory.CustomParams memory b = prepared(9_100_400);
        vm.expectRevert(Receiver.Creation.selector);
        receiver.forward(b.launchNumber, b.tokenCreationCode, a.contractCreationCodes[0]);
        unchanged(t, m, t.balanceOf(address(receiver)));
    }

    function testTask8CounterfeitCodeAndConstructorWords() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_500);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        bytes memory badToken = bytes.concat(p.tokenCreationCode, hex"00");
        vm.expectRevert(Receiver.Creation.selector);
        receiver.forward(p.launchNumber, badToken, p.contractCreationCodes[0]);
        bytes memory badMiner = bytes.concat(p.contractCreationCodes[0]);
        badMiner[0] ^= 0x01;
        vm.expectRevert(Receiver.Creation.selector);
        receiver.forward(p.launchNumber, p.tokenCreationCode, badMiner);
        for (uint256 i; i < 12; ++i) {
            badMiner = bytes.concat(p.contractCreationCodes[0]);
            badMiner[type(FinancierMiningWithAgents).creationCode.length + i * 32 + 31] ^= 0x01;
            vm.expectRevert(Receiver.Creation.selector);
            receiver.forward(p.launchNumber, p.tokenCreationCode, badMiner);
        }
        unchanged(t, m, held);
    }

    function testTask8RegistryWrongKindDuplicateAndWrongArtifacts() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_600);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        IIMDLaunchRegistry r = IIMDLaunchRegistry(FACTORY.registry());
        IIMDLaunchRegistry.Launch memory rec = r.launchOf(p.launchNumber);
        rec.kind = "evm_project";
        vm.mockCall(address(r), abi.encodeCall(r.launchOf, (p.launchNumber)), abi.encode(rec));
        vm.expectRevert(Receiver.Record.selector);
        forward(p);
        vm.clearMockedCalls();
        IIMDLaunchRegistry.Artifact[] memory original = r.artifactsOf(p.launchNumber);
        IIMDLaunchRegistry.Artifact[] memory duplicate = new IIMDLaunchRegistry.Artifact[](original.length + 1);
        for (uint256 i; i < original.length; ++i) {
            duplicate[i] = original[i];
        }
        duplicate[original.length] = IIMDLaunchRegistry.Artifact("token", "FINCR", address(t));
        vm.mockCall(address(r), abi.encodeCall(r.artifactsOf, (p.launchNumber)), abi.encode(duplicate));
        vm.expectRevert(Receiver.Artifacts.selector);
        forward(p);
        vm.clearMockedCalls();
        for (uint256 i; i < original.length; ++i) {
            if (original[i].role == "other") original[i].addr = address(999);
        }
        vm.mockCall(address(r), abi.encodeCall(r.artifactsOf, (p.launchNumber)), abi.encode(original));
        vm.expectRevert(Receiver.Artifacts.selector);
        forward(p);
        vm.clearMockedCalls();
        unchanged(t, m, t.balanceOf(address(receiver)));
    }

    function testTask8WrongChainFactoryRegistryAndVerifierDrift() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_700);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        vm.chainId(1);
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.chainId(4663);
        vm.mockCall(address(FACTORY), abi.encodeCall(FACTORY.registry, ()), abi.encode(address(999)));
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.clearMockedCalls();
        vm.mockCall(address(FACTORY), abi.encodeCall(FACTORY.deployer, ()), abi.encode(address(999)));
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.clearMockedCalls();
        bytes memory code = address(verifier).code;
        vm.etch(address(verifier), hex"00");
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.etch(address(verifier), code);
        unchanged(t, m, t.balanceOf(address(receiver)));
        forward(p);
    }

    function testTask8MisroutedRemainderCannotBeRecoveredOrArmed() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_500);
        p.remainderTo = address(777);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        assertGe(t.balanceOf(address(777)), 4e26);
        assertEq(t.balanceOf(address(receiver)), 0);
        vm.expectRevert(Receiver.Funding.selector);
        forward(p);
        assertFalse(m.armed());
        assertFalse(receiver.forwarded(address(t)));
        // Authenticated code cannot force an authorized factory deployer to route funds correctly.
    }

    function testTask8FactoryRegistryCodeAndWriterDriftRejected() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_600);
        launch(p);
        address registry = FACTORY.registry();
        vm.mockCall(registry, abi.encodeWithSignature("writer()"), abi.encode(address(999)));
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.clearMockedCalls();
        bytes memory code = registry.code;
        vm.etch(registry, hex"00");
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.etch(registry, code);
        code = address(FACTORY).code;
        vm.etch(address(FACTORY), hex"00");
        vm.expectRevert(Receiver.Authority.selector);
        forward(p);
        vm.etch(address(FACTORY), code);
        forward(p);
    }

    function testTask8InsufficientFundingSurplusAndFailedArmRollback() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_800);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        deal(address(t), address(receiver), 4e26 - 1);
        vm.expectRevert(Receiver.Funding.selector);
        forward(p);
        deal(address(t), address(receiver), held);
        vm.mockCallRevert(
            address(m), abi.encodeCall(m.arm, ()), abi.encodeWithSignature("Error(string)", "FAULT INJECTION")
        );
        vm.expectRevert(bytes("FAULT INJECTION"));
        forward(p);
        unchanged(t, m, held);
        vm.clearMockedCalls();
        forward(p);
        assertEq(t.balanceOf(address(receiver)), held - 4e26);
        vm.expectRevert(Receiver.Replay.selector);
        forward(p);
    }

    function testTask8IncompatibleTransferAndRuntimeFaultsRollback() public {
        IProjectFactory.CustomParams memory p = prepared(9_100_900);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        uint256 held = t.balanceOf(address(receiver));
        bytes memory code = address(t).code;
        vm.etch(address(t), hex"00");
        vm.expectRevert(Receiver.Target.selector);
        forward(p);
        vm.etch(address(t), code);
        vm.mockCall(address(t), abi.encodeCall(t.transfer, (address(m), 4e26)), abi.encode(true));
        vm.expectRevert(Receiver.Delivery.selector);
        forward(p);
        unchanged(t, m, held);
        vm.clearMockedCalls();
        forward(p);
    }

    /// No source attestation precommit means allocation/provenance approval is NOT authenticated.
    /// This negative result is intentional: safe routing alone is insufficient production policy.
    function testTask8WrongPoolBudgetStillPassesCustodyPredicate() public {
        IProjectFactory.CustomParams memory p = prepared(9_101_000);
        p.poolBps = 4000;
        p.liquidity = uint128(uint256(p.liquidity) * 4 / 5);
        (FINCR t, FinancierMiningWithAgents m,) = launch(p);
        assertGt(t.balanceOf(address(receiver)), 5e26 - 1000);
        forward(p);
        assertEq(t.balanceOf(address(m)), 4e26);
        assertGt(t.balanceOf(address(receiver)), 1e26 - 1000);
    }

    function testFuzzTask8ConstructorMutationCannotRedirect(uint8 word, uint8 delta) public {
        word = uint8(bound(word, 0, 11));
        delta = uint8(bound(delta, 1, 255));
        IProjectFactory.CustomParams memory p = prepared(9_101_100);
        p.contractCreationCodes[
            0
        ][type(FinancierMiningWithAgents).creationCode.length + uint256(word) * 32 + 31] ^= bytes1(delta);
        vm.expectRevert(Receiver.Creation.selector);
        forward(p);
    }
}

contract CounterfeitGetterMiner {
    address public immutable fincr;
    address public immutable initializer;

    constructor(address token, address init) {
        fincr = token;
        initializer = init;
    }

    function initialSupply() external pure returns (uint256) {
        return 1e27;
    }

    function miningReserve() external pure returns (uint256) {
        return 4e26;
    }

    function armed() external pure returns (bool) {
        return false;
    }

    function epoch() external pure returns (uint256) {
        return 0;
    }

    function genesis() external pure returns (uint256) {
        return 0;
    }
    function arm() external {}
}

contract ReentrantTransfer {
    function transfer(address, uint256) external returns (bool) {
        // Would call the receiver recursively if allowed past exact runtime authentication.
        Receiver(msg.sender).forward(1, "", "");
        return true;
    }
}
