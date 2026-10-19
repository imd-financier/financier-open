// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {FINCR} from "../../src/FINCR.sol";
import {FinancierMiningWithMarket as Mining} from "../../src/FinancierMiningWithMarket.sol";
import {RestrictedMarketReserveReceiver as Receiver} from "../../src/RestrictedMarketReserveReceiver.sol";
import {AttestedAgentRounds as Rounds} from "../../src/AttestedAgentRounds.sol";
import {IAgentWorkVerifier as W} from "../../src/interfaces/IAgentWorkVerifier.sol";
import {IIMDLaunchRegistry as Registry} from "../../src/interfaces/IIMDLaunch.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IImdTransfers} from "./Task23Base.sol";
import {LaunchRegistryMock, ProjectFactoryMock} from "./LaunchMocks.sol";

/// Synthetic authority/ownership and mutable registry MODEL, never official admission.
abstract contract Task23ReceiverBase is Test {
    uint256 constant SUPPLY = 1e27;
    uint256 constant RESERVE = 4e26;
    address constant BOOTSTRAP = address(701);
    address constant SETTLER = address(702);
    address constant ALICE = address(101);
    address constant BOB = address(102);
    bytes32 constant POLICY = keccak256("LOCAL FINANCIER accepted-set policy; candidate only");
    bytes32 constant REVIEW = keccak256("LOCAL SYNTHETIC launch/source/allocation review");
    LaunchRegistryMock registry;
    ProjectFactoryMock factory;
    Receiver receiver;
    IERC20 imd;
    FINCR token;
    Mining miner;
    Rounds rounds;
    bytes tokenInit;
    bytes minerInit;
    Receiver.Pins pins;
    Receiver.Settings settings;
    uint64 constant NUMBER = 15001;

    function setUp() public virtual {
        vm.chainId(4663);
        vm.warp(1_000_000);
        registry = new LaunchRegistryMock();
        factory = new ProjectFactoryMock(address(registry));
        vm.mockCall(address(registry), abi.encodeWithSignature("writer()"), abi.encode(address(factory)));
        address asset = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
        vm.etch(asset, vm.parseBytes(vm.readLine("test/fixtures/task16/imd-runtime.hex")));
        vm.store(asset, bytes32(0), bytes32(uint256(uint160(address(this)))));
        IImdTransfers(asset).enableTransfers();
        vm.etch(
            0x8366a39CC670B4001A1121B8F6A443A643e40951,
            vm.parseBytes(vm.readLine("test/fixtures/task23/manager-runtime.hex"))
        );
        vm.etch(
            0x19Bec7C2E1b2aadAf67b259744751a9960d66000,
            vm.parseBytes(vm.readLine("test/fixtures/task23/guard-runtime.hex"))
        );
        imd = IERC20(asset);
        FINCR probe = new FINCR(SUPPLY);
        tokenInit = abi.encodePacked(type(FINCR).creationCode, abi.encode(SUPPLY));
        pins = Receiver.Pins(
            address(factory),
            address(registry),
            address(this),
            address(factory).codehash,
            address(registry).codehash,
            keccak256(tokenInit),
            address(probe).codehash,
            keccak256(type(Mining).creationCode),
            type(Mining).creationCode.length
        );
        settings = Receiver.Settings(
            address(imd), SUPPLY, 1 ether, 1 ether, address(105), SETTLER, POLICY, 1 days, 1 days, 1 hours, 1 ether
        );
        receiver = new Receiver(pins, settings, BOOTSTRAP);
        (token, miner) = launchModel(NUMBER);
        rounds = miner.agentRounds();
        minerInit = bytes.concat(type(Mining).creationCode, receiver.minerArguments(address(token)));
        deal(address(imd), ALICE, 100 ether);
        deal(address(imd), BOB, 100 ether);
        vm.prank(ALICE);
        imd.approve(address(miner), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(miner), type(uint256).max);
    }

    function launchModel(uint64 number) internal returns (FINCR t, Mining m) {
        address predicted = factory.predictToken(number, tokenInit);
        bytes memory code = bytes.concat(type(Mining).creationCode, receiver.minerArguments(predicted));
        Registry.Launch memory rec = Registry.Launch(
            "custom_token",
            number,
            uint64(block.timestamp),
            keccak256("source"),
            keccak256("manifest"),
            keccak256("attestation"),
            keccak256("verifier"),
            "https://example.invalid/local-model"
        );
        (address token_, address miner_) = factory.launch(tokenInit, code, rec, address(receiver));
        // Old mutable mock labels its app with the old class name; use the new exact artifact.
        Registry.Artifact[] memory a = new Registry.Artifact[](2);
        a[0] = Registry.Artifact("token", "FINCR", token_);
        a[1] = Registry.Artifact("other", "FinancierMiningWithMarket", miner_);
        registry.setArtifacts(number, a);
        return (FINCR(token_), Mining(miner_));
    }

    function bootstrap() internal {
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, tokenInit, minerInit, REVIEW);
    }
}
