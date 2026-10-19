// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {IProjectFactory} from "./IProjectFactory.sol";
import {IIMDLaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";
import {FinancierMiningWithAgents} from "../../src/FinancierMiningWithAgents.sol";
import {ReserveForwarder} from "../../src/ReserveForwarder.sol";
import {UnavailableWorkVerifier} from "../../src/UnavailableWorkVerifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FINCR} from "../../src/FINCR.sol";

interface IRegistryWriter {
    function writer() external view returns (address);
    function record(IIMDLaunchRegistry.Launch calldata, IIMDLaunchRegistry.Artifact[] calldata, uint256[] calldata)
        external;
}

/// ONLY run against the loopback Anvil fork via script/rehearse-real-factory.py (no broadcast).
contract RobinhoodFactoryForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0x9C9D2FCB75c2C132C0AC0C42DF3819A42347265e);

    function setUp() public virtual {
        require(block.chainid == 4663, "wrong fork chain");
        require(
            address(FACTORY).codehash == 0x46c834a83deedf1fe46fe2161fcf49fe5b93af45e08bb7dbe0d7ecc31ee07a4b,
            "factory runtime drift"
        );
    }

    function params() internal view returns (IProjectFactory.CustomParams memory p) {
        bytes memory input =
            vm.parseJsonBytes(vm.readFile("test/fixtures/real-chain/launch-1727-calldata.json"), ".calldata");
        assertEq(bytes4(input), IProjectFactory.launchCustom.selector);
        bytes memory args = new bytes(input.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = input[i + 4];
        }
        p = abi.decode(args, (IProjectFactory.CustomParams));
    }

    function testRecordedLaunchRegistryAndPredictions() public view {
        IProjectFactory.CustomParams memory p = params();
        assertEq(p.launchNumber, 1727);
        assertEq(FACTORY.predictToken(p.launchNumber, p.tokenCreationCode), 0xc0A47175CfCd6130d6F17DDCFDA59a47221D4250);
        IIMDLaunchRegistry registry = IIMDLaunchRegistry(FACTORY.registry());
        IIMDLaunchRegistry.Launch memory r = registry.launchOf(1727);
        assertEq(r.kind, bytes32("custom_token"));
        assertEq(r.sourceCommit, p.record.sourceCommit);
        assertEq(r.attestationHash, p.record.attestationHash);
        assertEq(r.manifestHash, p.record.manifestHash);
        assertEq(registry.artifactsOf(1727)[0].addr, FACTORY.predictToken(1727, p.tokenCreationCode));
    }

    function testPredictionCommitsCodeNumberAndIndexButNotSourceAttestation() public {
        IProjectFactory.CustomParams memory p = customFincrParams(9_000_300);
        address token = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        assertNotEq(token, FACTORY.predictToken(p.launchNumber + 1, p.tokenCreationCode));
        assertNotEq(token, FACTORY.predictToken(p.launchNumber, bytes.concat(p.tokenCreationCode, hex"00")));
        address app = FACTORY.predictContract(p.launchNumber, 0, p.tokenCreationCode);
        assertNotEq(app, FACTORY.predictContract(p.launchNumber, 1, p.tokenCreationCode));
        assertNotEq(app, FACTORY.predictContract(p.launchNumber + 1, 0, p.tokenCreationCode));
        assertNotEq(app, FACTORY.predictContract(p.launchNumber, 0, bytes.concat(p.tokenCreationCode, hex"00")));

        // The real factory accepts provenance supplied by its privileged deployer.
        // This is NOT a service-generated attestation or permission to trust arbitrary records.
        p.record.sourceCommit = keccak256("TASK6 SYNTHETIC SOURCE");
        p.record.manifestHash = keccak256("TASK6 SYNTHETIC MANIFEST");
        p.record.attestationHash = keccak256("TASK6 SYNTHETIC ATTESTATION");
        p.record.verifierKey = keccak256("TASK6 SYNTHETIC VERIFIER");
        assertEq(token, FACTORY.predictToken(p.launchNumber, p.tokenCreationCode));
        vm.prank(FACTORY.deployer());
        (address deployed,,) = FACTORY.launchCustom(p);
        assertEq(deployed, token);
        IIMDLaunchRegistry.Launch memory r = IIMDLaunchRegistry(FACTORY.registry()).launchOf(p.launchNumber);
        assertEq(r.sourceCommit, p.record.sourceCommit);
        assertEq(r.manifestHash, p.record.manifestHash);
        assertEq(r.attestationHash, p.record.attestationHash);
        assertEq(r.verifierKey, p.record.verifierKey);
    }

    // Raw deployed revert data captured in docs/evidence/readiness/pr7-review/before-rejections.log.
    // Names of the factory/registry errors are not asserted without verified source.
    bytes4 constant FACTORY_AUTH_ERROR = 0x8b906c97;
    bytes4 constant REGISTRY_AUTH_ERROR = 0x751a1cd0;
    bytes4 constant REGISTRY_DUPLICATE_ERROR = 0xf6b9daca;

    function customFincrParams(uint64 number) internal view returns (IProjectFactory.CustomParams memory p) {
        p = params();
        p.launchNumber = number;
        p.record.launchNumber = p.launchNumber;
        p.record.recordedAt = uint64(block.timestamp);
        p.tokenCreationCode = abi.encodePacked(type(FINCR).creationCode, abi.encode(1e27));
        p.tokenName = "FINCR";
        p.liquidity = uint128(uint256(p.liquidity) * 5000 / 8800);
        p.poolBps = 5000;
        p.remainderTo = address(this);
        p.requester = address(this);
        // Synthetic local launch record, NOT an official source-admission attestation.
        p.record.sourceCommit = keccak256("LOCAL FORK ONLY");
        p.record.attestationHash = keccak256("NOT OFFICIAL ATTESTATION");
        address expected = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        for (uint256 i; expected < p.pairedCurrency && i < 32; ++i) {
            p.launchNumber++;
            p.record.launchNumber = p.launchNumber;
            expected = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        }
        require(expected > p.pairedCurrency, "fixture currency ordering");
    }

    function testRealFactoryRejectsUnauthorizedCaller() public {
        IProjectFactory.CustomParams memory p = customFincrParams(9_000_001);
        address expected = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        IIMDLaunchRegistry registry = IIMDLaunchRegistry(FACTORY.registry());
        assertEq(expected.code.length, 0);
        assertEq(registry.launchOf(p.launchNumber).recordedAt, 0);
        vm.expectRevert(abi.encodePacked(FACTORY_AUTH_ERROR));
        FACTORY.launchCustom(p);
        assertEq(expected.code.length, 0);
        assertEq(registry.launchOf(p.launchNumber).recordedAt, 0);
        assertEq(registry.artifactsOf(p.launchNumber).length, 0);

        // Same exact calldata succeeds when only caller changes to the actual deployer.
        address deployer = FACTORY.deployer();
        vm.prank(deployer);
        (address token,,) = FACTORY.launchCustom(p);
        assertEq(token, expected);
        assertGt(token.code.length, 0);
        assertEq(registry.launchOf(p.launchNumber).attestationHash, p.record.attestationHash);
    }

    function testRealFactoryCustomFincrAndSupplyReducingBurn() public {
        IProjectFactory.CustomParams memory p = customFincrParams(9_000_002);
        address expected = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        vm.prank(FACTORY.deployer());
        (address token,, address distributor) = FACTORY.launchCustom(p);
        assertEq(token, expected);
        assertGt(distributor.code.length, 0);
        uint256 received = FINCR(token).balanceOf(address(this));
        assertGe(received, 4e26);
        assertEq(FINCR(token).balanceOf(distributor), 1e26);
        FINCR(token).burn(1 ether);
        assertEq(FINCR(token).totalSupply(), 1e27 - 1 ether);
        emit log_named_uint("Actual fork remainder including unspent pool rounding", received);
    }

    function testRealFactoryForwarderMiningAndClaims() public {
        IProjectFactory.CustomParams memory p = params();
        p.launchNumber = 9_000_100;
        p.record.launchNumber = p.launchNumber;
        p.record.recordedAt = uint64(block.timestamp);
        p.tokenCreationCode = abi.encodePacked(type(FINCR).creationCode, abi.encode(1e27));
        p.tokenName = "FINCR";
        p.poolBps = 5000;
        p.liquidity = uint128(uint256(p.liquidity) * 5000 / 8800);
        p.requester = address(this);
        p.record.sourceCommit = keccak256("LOCAL FORK ONLY");
        p.record.attestationHash = keccak256("SYNTHETIC: NO OFFICIAL ADMISSION");
        address predictedToken = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        for (uint256 i; predictedToken < p.pairedCurrency && i < 32; ++i) {
            p.launchNumber++;
            p.record.launchNumber = p.launchNumber;
            predictedToken = FACTORY.predictToken(p.launchNumber, p.tokenCreationCode);
        }
        require(predictedToken > p.pairedCurrency, "fixture currency ordering");
        UnavailableWorkVerifier verifier = new UnavailableWorkVerifier();
        address predictedForwarder = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        p.remainderTo = predictedForwarder;
        p.contractCreationCodes = new bytes[](1);
        p.contractNames = new bytes32[](1);
        p.expectedContracts = new address[](1);
        p.contractNames[0] = "FinancierMiningWithAgents";
        p.contractCreationCodes[0] = abi.encodePacked(
            type(FinancierMiningWithAgents).creationCode,
            abi.encode(
                predictedToken,
                p.pairedCurrency,
                uint256(1e27),
                uint256(1 ether),
                uint256(1 ether),
                predictedForwarder,
                address(105),
                address(verifier),
                keccak256("LOCAL POLICY"),
                uint256(1 days),
                uint256(1 days),
                uint256(1 hours)
            )
        );
        p.expectedContracts[0] = FACTORY.predictContract(p.launchNumber, 0, p.contractCreationCodes[0]);
        IIMDLaunchRegistry.Launch memory r = p.record;
        ReserveForwarder.Config memory c = ReserveForwarder.Config(
            address(FACTORY),
            FACTORY.registry(),
            FACTORY.deployer(),
            address(FACTORY).codehash,
            FACTORY.registry().codehash,
            p.launchNumber,
            0,
            1e27,
            keccak256(
                abi.encode(
                    r.kind,
                    r.launchNumber,
                    r.sourceCommit,
                    r.manifestHash,
                    r.attestationHash,
                    r.verifierKey,
                    keccak256(bytes(r.sourceRepoUrl))
                )
            ),
            keccak256(p.tokenCreationCode),
            keccak256(p.contractCreationCodes[0]),
            bytes32(uint256(1)),
            bytes32(uint256(1)),
            bytes32(uint256(1))
        );
        uint256 snapshot = vm.snapshotState();
        ReserveForwarder probe = new ReserveForwarder(c);
        assertEq(address(probe), predictedForwarder);
        vm.prank(FACTORY.deployer());
        (address token, address[] memory apps,) = FACTORY.launchCustom(p);
        c.tokenRuntimeHash = token.codehash;
        c.minerRuntimeHash = apps[0].codehash;
        c.minerConfigHash = probe.configHash(FinancierMiningWithAgents(apps[0]));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        ReserveForwarder forwarder = new ReserveForwarder(c);
        assertEq(address(forwarder), predictedForwarder);
        vm.prank(FACTORY.deployer());
        (token, apps,) = FACTORY.launchCustom(p);
        FinancierMiningWithAgents miner = FinancierMiningWithAgents(apps[0]);
        assertEq(address(miner), p.expectedContracts[0]);
        assertFalse(miner.armed());
        assertEq(miner.epoch(), 0);
        vm.prank(address(999));
        forwarder.forward(p.tokenCreationCode, p.contractCreationCodes[0]);
        assertTrue(miner.armed());
        assertEq(miner.epoch(), 0);
        assertEq(miner.genesis(), 0);
        assertEq(FINCR(token).balanceOf(address(miner)), 4e26);
        IERC20 imd = IERC20(p.pairedCurrency);
        // Forge-only balance storage injection; NO real token transfer or minted IMD.
        deal(address(imd), address(101), 10 ether);
        deal(address(imd), address(102), 10 ether);
        vm.startPrank(address(101));
        imd.approve(address(miner), 10 ether);
        miner.bid(0, 1 ether, block.timestamp);
        vm.stopPrank();
        uint256 genesis = miner.genesis();
        vm.warp(genesis + 1 hours);
        vm.startPrank(address(102));
        imd.approve(address(miner), 10 ether);
        miner.bid(1, 1 ether, block.timestamp);
        vm.stopPrank();
        assertEq(miner.outgoingCredit(address(101)), 0.8 ether);
        vm.startPrank(address(101));
        assertGt(miner.claimFincr(), 0);
        assertEq(miner.claimImd(), 0.8 ether);
        vm.stopPrank();
        vm.warp(genesis + 366 days);
        miner.agentRounds().expire(0);
        vm.prank(address(102));
        assertGt(miner.claimFincr(), 0);
        assertEq(miner.totalFincrPaid(), 3.2e26);
        assertEq(miner.totalAgentPaid(), 0);
        assertEq(FINCR(token).balanceOf(address(miner)), 8e25);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
        assertEq(miner.genesis(), genesis);
    }

    function testActualRegistryWriterAndNoOverwrite() public {
        IRegistryWriter registry = IRegistryWriter(FACTORY.registry());
        assertEq(registry.writer(), address(FACTORY));
        IProjectFactory.CustomParams memory p = params();
        IIMDLaunchRegistry.Artifact[] memory artifacts = IIMDLaunchRegistry(address(registry)).artifactsOf(1727);
        // Valid fresh record: first show identical data succeeds for the writer, then
        // its exact replay fails only once the record exists. No invalid-price/pool path.
        p.record.launchNumber = 9_000_200;
        p.record.recordedAt = uint64(block.timestamp);
        assertEq(IIMDLaunchRegistry(address(registry)).launchOf(p.record.launchNumber).recordedAt, 0);
        vm.expectRevert(abi.encodePacked(REGISTRY_AUTH_ERROR));
        registry.record(p.record, artifacts, p.agentIds);
        assertEq(IIMDLaunchRegistry(address(registry)).launchOf(p.record.launchNumber).recordedAt, 0);
        assertEq(IIMDLaunchRegistry(address(registry)).artifactsOf(p.record.launchNumber).length, 0);
        vm.prank(address(FACTORY));
        registry.record(p.record, artifacts, p.agentIds);
        bytes32 recordBefore =
            keccak256(abi.encode(IIMDLaunchRegistry(address(registry)).launchOf(p.record.launchNumber)));
        bytes32 artifactsBefore =
            keccak256(abi.encode(IIMDLaunchRegistry(address(registry)).artifactsOf(p.record.launchNumber)));
        assertEq(recordBefore, keccak256(abi.encode(p.record)));
        assertEq(artifactsBefore, keccak256(abi.encode(artifacts)));
        vm.prank(address(FACTORY));
        vm.expectRevert(abi.encodePacked(REGISTRY_DUPLICATE_ERROR, abi.encode(uint256(p.record.launchNumber))));
        registry.record(p.record, artifacts, p.agentIds);
        assertEq(
            keccak256(abi.encode(IIMDLaunchRegistry(address(registry)).launchOf(p.record.launchNumber))), recordBefore
        );
        assertEq(
            keccak256(abi.encode(IIMDLaunchRegistry(address(registry)).artifactsOf(p.record.launchNumber))),
            artifactsBefore
        );
    }
}
