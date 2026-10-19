// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IntegrationBase} from "./helpers/IntegrationBase.sol";
import {ReserveForwarder} from "../src/ReserveForwarder.sol";
import {FinancierMining} from "../src/FinancierMining.sol";
import {IIMDLaunchRegistry} from "../src/interfaces/IIMDLaunch.sol";
import {LaunchTokenMock} from "./helpers/LaunchMocks.sol";

contract CounterfeitMiner {
    address public fincr;
    address public initializer;
    uint256 public constant initialSupply = 1e27;
    uint256 public constant miningReserve = 4e26;

    constructor(address t, address i) {
        fincr = t;
        initializer = i;
    }
    function arm() external {}
}

contract ReserveForwarderTest is IntegrationBase {
    function setUp() public {
        deployIntegration(false);
    }

    function testLocalOfficialInterfaceLaunchFundingAndPublicBidGenesis() public {
        assertEq(token.balanceOf(address(forwarder)), RESERVE);
        assertEq(token.balanceOf(address(201)), SUPPLY / 2);
        assertEq(token.balanceOf(address(202)), SUPPLY / 10);
        vm.warp(block.timestamp + 1 days);
        vm.prank(BOB); // front-running trigger cannot redirect
        forwarder.forward(tokenCode, minerCode);
        assertTrue(miner.armed());
        assertEq(miner.epoch(), 0);
        assertEq(miner.genesis(), 0);
        assertEq(token.balanceOf(address(miner)), RESERVE);
        assertEq(token.balanceOf(address(forwarder)), 0);
        vm.warp(block.timestamp + 10 days);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.genesis(), block.timestamp);
        assertEq(miner.claimableFincr(ALICE), 0);
        vm.expectRevert(ReserveForwarder.AlreadyForwarded.selector);
        forwarder.forward(tokenCode, minerCode);
    }

    function testPrematureUnauthorizedArmAndMissingReserve() public {
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        miner.arm();
        vm.expectRevert(FinancierMining.Unfunded.selector);
        vm.prank(address(forwarder));
        miner.arm();
        deal(address(token), address(forwarder), RESERVE - 1);
        vm.expectRevert(ReserveForwarder.MissingReserve.selector);
        forwarder.forward(tokenCode, minerCode);
        assertFalse(forwarder.forwarded());
        assertFalse(miner.armed());
    }

    function testWrongLaunchSourceManifestAndAttestation() public {
        IIMDLaunchRegistry.Launch memory r = record;
        r.launchNumber++;
        registry.setRecord(LAUNCH, r);
        vm.expectRevert(ReserveForwarder.WrongLaunch.selector);
        forwarder.forward(tokenCode, minerCode);
        r = record;
        r.sourceCommit = keccak256("other source");
        registry.setRecord(LAUNCH, r);
        vm.expectRevert(ReserveForwarder.WrongLaunch.selector);
        forwarder.forward(tokenCode, minerCode);
        r = record;
        r.manifestHash = keccak256("other manifest");
        registry.setRecord(LAUNCH, r);
        vm.expectRevert(ReserveForwarder.WrongLaunch.selector);
        forwarder.forward(tokenCode, minerCode);
        r = record;
        r.attestationHash = keccak256("other attestation");
        registry.setRecord(LAUNCH, r);
        vm.expectRevert(ReserveForwarder.WrongLaunch.selector);
        forwarder.forward(tokenCode, minerCode);
        r = record;
        r.recordedAt = 0;
        registry.setRecord(LAUNCH, r);
        vm.expectRevert(ReserveForwarder.WrongLaunch.selector);
        forwarder.forward(tokenCode, minerCode);
    }

    function testWrongTokenAndCounterfeitMatchingViews() public {
        IIMDLaunchRegistry.Artifact[] memory a = registry.artifactsOf(LAUNCH);
        a[0].addr = address(imd);
        registry.setArtifacts(LAUNCH, a);
        vm.expectRevert(ReserveForwarder.WrongArtifact.selector);
        forwarder.forward(tokenCode, minerCode);
        a[0].addr = address(token);
        CounterfeitMiner fake = new CounterfeitMiner(address(token), address(forwarder));
        a[1].addr = address(fake);
        registry.setArtifacts(LAUNCH, a);
        vm.expectRevert(ReserveForwarder.WrongArtifact.selector);
        forwarder.forward(tokenCode, minerCode);
        assertEq(token.balanceOf(address(fake)), 0);
        // Even a matching-view counterfeit at the predicted address fails the runtime hash pin.
        vm.etch(address(miner), address(fake).code);
        vm.expectRevert(ReserveForwarder.WrongTarget.selector);
        forwarder.forward(tokenCode, minerCode);
    }

    function testCreationSubstitutionAndAnotherLaunchCannotUseReserve() public {
        vm.expectRevert(ReserveForwarder.WrongCreationCode.selector);
        forwarder.forward(abi.encodePacked(tokenCode, bytes1(0)), minerCode);
        vm.expectRevert(ReserveForwarder.WrongCreationCode.selector);
        forwarder.forward(tokenCode, abi.encodePacked(minerCode, bytes1(0)));
        IIMDLaunchRegistry.Launch memory r = record;
        r.launchNumber = LAUNCH + 1;
        registry.setRecord(LAUNCH + 1, r);
        (bool ok,) = address(forwarder).call(abi.encodeWithSignature("forward(uint64)", LAUNCH + 1));
        assertFalse(ok);
        assertEq(token.balanceOf(address(forwarder)), RESERVE);
    }

    function testFactoryRegistryAndChainPins() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert(ReserveForwarder.WrongAuthority.selector);
        forwarder.forward(tokenCode, minerCode);
        vm.chainId(block.chainid - 1);
        vm.mockCall(address(factory), abi.encodeWithSignature("registry()"), abi.encode(address(123)));
        vm.expectRevert(ReserveForwarder.WrongAuthority.selector);
        forwarder.forward(tokenCode, minerCode);
        vm.clearMockedCalls();
        vm.mockCall(address(factory), abi.encodeWithSignature("deployer()"), abi.encode(BOB));
        vm.expectRevert(ReserveForwarder.WrongAuthority.selector);
        forwarder.forward(tokenCode, minerCode);
        vm.clearMockedCalls();
        bytes memory originalFactory = address(factory).code;
        vm.etch(address(factory), hex"00");
        vm.expectRevert(ReserveForwarder.WrongAuthority.selector);
        forwarder.forward(tokenCode, minerCode);
        vm.etch(address(factory), originalFactory);
        vm.etch(address(registry), hex"00");
        vm.expectRevert(ReserveForwarder.WrongAuthority.selector);
        forwarder.forward(tokenCode, minerCode);
    }

    function testBlockedTransferRollsBackForwardingAndArming() public {
        vm.mockCallRevert(
            address(token), abi.encodeWithSelector(token.transfer.selector, address(miner), RESERVE), "fixture failure"
        );
        vm.expectRevert();
        forwarder.forward(tokenCode, minerCode);
        assertFalse(forwarder.forwarded());
        assertFalse(miner.armed());
        assertEq(token.balanceOf(address(forwarder)), RESERVE);
        vm.clearMockedCalls();
        forwarder.forward(tokenCode, minerCode);
        assertTrue(miner.armed());
    }

    function testFuzzDonationCannotIncreaseForwardedReserve(uint128 extra) public {
        deal(address(token), address(forwarder), RESERVE + uint256(extra));
        forwarder.forward(tokenCode, minerCode);
        assertEq(token.balanceOf(address(miner)), RESERVE);
        assertEq(token.balanceOf(address(forwarder)), uint256(extra));
        assertEq(miner.miningReserve(), RESERVE);
        (bool ok,) = address(forwarder).call(abi.encodeWithSignature("rescue(address,address)", address(token), BOB));
        assertFalse(ok);
    }
}

contract ForwarderMaliciousTokenTest is IntegrationBase {
    function setUp() public {
        deployIntegration(true);
    }

    function testTaxedReserveRejected() public {
        LaunchTokenMock(address(token)).configure(true, address(0), "");
        vm.expectRevert(ReserveForwarder.InexactForward.selector);
        forwarder.forward(tokenCode, minerCode);
        assertFalse(forwarder.forwarded());
        assertEq(token.balanceOf(address(forwarder)), RESERVE);
    }

    function testForwardReentrancyBlocked() public {
        LaunchTokenMock t = LaunchTokenMock(address(token));
        t.configure(false, address(forwarder), abi.encodeCall(forwarder.forward, (tokenCode, minerCode)));
        forwarder.forward(tokenCode, minerCode);
        assertTrue(t.attempted());
        assertFalse(t.reentered());
        assertTrue(miner.armed());
        assertEq(miner.epoch(), 0);
    }
}
