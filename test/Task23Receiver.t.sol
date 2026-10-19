// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Task23ReceiverBase, Receiver, FINCR, Mining, Registry} from "./helpers/Task23ReceiverBase.sol";
import {FinancierMining} from "../src/FinancierMining.sol";

contract Task23ReceiverTest is Task23ReceiverBase {
    function testReceiverRejectsUnlaunchableSettingsBeforeReceivingFunds() public {
        (Receiver.Pins memory p, Receiver.Settings memory s) = receiver.configuration();
        s.policy = 0;
        vm.expectRevert(bytes("settings"));
        new Receiver(p, s, BOOTSTRAP);
        s.policy = keccak256("policy");
        s.operations = address(0);
        vm.expectRevert(bytes("settings"));
        new Receiver(p, s, BOOTSTRAP);
        s.operations = address(7);
        s.roundSeconds = 0;
        vm.expectRevert(bytes("settings"));
        new Receiver(p, s, BOOTSTRAP);
    }

    function testWrongTokenOrCounterfeitMinerArtifactCannotChooseDestination() public {
        Registry.Artifact[] memory a = new Registry.Artifact[](2);
        a[0] = Registry.Artifact("token", "FINCR", address(999));
        a[1] = Registry.Artifact("other", "FinancierMiningWithMarket", address(miner));
        registry.setArtifacts(NUMBER, a);
        vm.expectRevert(Receiver.Artifacts.selector);
        bootstrap();
        a[0].addr = address(token);
        a[1].addr = address(888);
        registry.setArtifacts(NUMBER, a);
        vm.expectRevert(Receiver.Artifacts.selector);
        bootstrap();
        assertUntouched();
    }

    function assertUntouched() internal view {
        assertFalse(receiver.bootstrapped());
        assertFalse(miner.armed());
        assertEq(token.balanceOf(address(miner)), 0);
        assertEq(token.balanceOf(address(receiver)), RESERVE);
    }

    function testOnlyAuthorityAtomicSetupAndFirstPublicBidGenesis() public {
        assertUntouched();
        vm.expectRevert(Receiver.Authority.selector);
        receiver.bootstrap(NUMBER, tokenInit, minerInit, REVIEW);
        vm.expectRevert(FinancierMining.Unauthorized.selector);
        miner.arm();
        vm.expectRevert(FinancierMining.NotArmed.selector);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        vm.warp(block.timestamp + 3 days);
        bootstrap();
        assertTrue(receiver.bootstrapped());
        assertTrue(miner.armed());
        assertEq(receiver.canonicalToken(), address(token));
        assertEq(receiver.canonicalMiner(), address(miner));
        assertEq(receiver.bootstrapReviewHash(), REVIEW);
        assertEq(miner.genesis(), 0);
        assertEq(miner.epoch(), 0);
        assertEq(miner.iFinancier(), address(0));
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        miner.bid(0, 1 ether, block.timestamp);
        assertEq(miner.genesis(), block.timestamp);
        assertEq(miner.claimableFincr(ALICE), 0);
        vm.expectRevert(Receiver.Replay.selector);
        bootstrap();
        assertEq(token.balanceOf(address(miner)), RESERVE);
    }

    function testMatchingEarlyLaunchCannotSelectOrConsumeAuthorization() public {
        (FINCR other, Mining otherMiner) = launchModel(NUMBER + 1);
        bytes memory otherInit = bytes.concat(type(Mining).creationCode, receiver.minerArguments(address(other)));
        vm.expectRevert(Receiver.Authority.selector);
        receiver.bootstrap(NUMBER + 1, tokenInit, otherInit, REVIEW);
        assertFalse(receiver.bootstrapped());
        bootstrap();
        assertFalse(otherMiner.armed());
        assertEq(other.balanceOf(address(receiver)), RESERVE);
        vm.expectRevert(Receiver.Replay.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER + 1, tokenInit, otherInit, REVIEW);
    }

    function testDonationsCannotSelectAndExcessNeverIncreasesReserve() public {
        FINCR unrelated = new FINCR(SUPPLY);
        unrelated.transfer(address(receiver), 999);
        assertFalse(receiver.bootstrapped());
        deal(address(token), address(receiver), RESERVE + 777);
        deal(address(token), address(miner), 333);
        bootstrap();
        assertEq(token.balanceOf(address(receiver)), 777);
        assertEq(token.balanceOf(address(miner)), RESERVE + 333);
        assertEq(miner.miningReserve(), RESERVE);
        assertEq(unrelated.balanceOf(address(receiver)), 999);
        vm.prank(BOOTSTRAP);
        (bool ok,) = address(receiver).call(abi.encodeWithSignature("withdraw(address,uint256)", address(token), 777));
        assertFalse(ok);
    }

    function testMissingFundingAndFailedArmRollbackDoNotConsumeAuthorization() public {
        deal(address(token), address(receiver), RESERVE - 1);
        vm.expectRevert(Receiver.Funding.selector);
        bootstrap();
        assertFalse(receiver.bootstrapped());
        deal(address(token), address(receiver), RESERVE);
        vm.mockCallRevert(
            address(miner), abi.encodeCall(miner.arm, ()), abi.encodeWithSignature("Error(string)", "arm failure")
        );
        vm.expectRevert(bytes("arm failure"));
        bootstrap();
        assertUntouched();
        vm.clearMockedCalls();
        vm.mockCall(address(registry), abi.encodeWithSignature("writer()"), abi.encode(address(factory)));
        bootstrap();
    }

    function testInexactTransferAndRuntimeSubstitutionFailClosed() public {
        vm.mockCall(address(token), abi.encodeCall(token.transfer, (address(miner), RESERVE)), abi.encode(true));
        vm.expectRevert(Receiver.Delivery.selector);
        bootstrap();
        assertUntouched();
        vm.clearMockedCalls();
        vm.mockCall(address(registry), abi.encodeWithSignature("writer()"), abi.encode(address(factory)));
        bytes memory code = address(token).code;
        vm.etch(address(token), hex"00");
        vm.expectRevert(Receiver.Target.selector);
        bootstrap();
        assertFalse(receiver.bootstrapped());
        vm.etch(address(token), code);
        bootstrap();
    }

    function testWrongRecordsDuplicateArtifactsAndWrongReviewRejected() public {
        vm.expectRevert(Receiver.Record.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, tokenInit, minerInit, 0);
        Registry.Launch memory rec = registry.launchOf(NUMBER);
        rec.kind = "evm_contracts";
        registry.setRecord(NUMBER, rec);
        vm.expectRevert(Receiver.Record.selector);
        bootstrap();
        rec.kind = "custom_token";
        registry.setRecord(NUMBER, rec);
        Registry.Artifact[] memory a = new Registry.Artifact[](3);
        a[0] = Registry.Artifact("token", "FINCR", address(token));
        a[1] = Registry.Artifact("other", "FinancierMiningWithMarket", address(miner));
        a[2] = a[0];
        registry.setArtifacts(NUMBER, a);
        vm.expectRevert(Receiver.Artifacts.selector);
        bootstrap();
        assertUntouched();
    }

    function testAuthorityChainFactoryAndRegistryDrift() public {
        vm.chainId(1);
        vm.expectRevert(Receiver.Authority.selector);
        bootstrap();
        vm.chainId(4663);
        vm.mockCall(address(factory), abi.encodeWithSignature("deployer()"), abi.encode(address(999)));
        vm.expectRevert(Receiver.Authority.selector);
        bootstrap();
        vm.clearMockedCalls();
        vm.mockCall(address(registry), abi.encodeWithSignature("writer()"), abi.encode(address(999)));
        vm.expectRevert(Receiver.Authority.selector);
        bootstrap();
        assertUntouched();
    }

    function testSourceAssertionsAreFounderReviewedNotIndependentProof() public {
        Registry.Launch memory rec = registry.launchOf(NUMBER);
        rec.sourceCommit = keccak256("DEPLOYER ASSERTION");
        registry.setRecord(NUMBER, rec);
        bootstrap(); // Truth of this field belongs to the explicit founder review.
        assertTrue(miner.armed());
    }

    function testFuzzCodeOrConstructorMutationRejected(uint8 word, uint8 delta) public {
        word = uint8(bound(word, 0, 12));
        delta = uint8(bound(delta, 1, 255));
        bytes memory bad = bytes.concat(minerInit);
        bad[type(Mining).creationCode.length + uint256(word) * 32 + 31] ^= bytes1(delta);
        vm.expectRevert(Receiver.Creation.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, tokenInit, bad, REVIEW);
        assertUntouched();
    }

    function testTokenCreationAndMinerPrefixMutationRejected() public {
        vm.expectRevert(Receiver.Creation.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, bytes.concat(tokenInit, hex"00"), minerInit, REVIEW);
        bytes memory bad = bytes.concat(minerInit);
        bad[0] ^= 0x01;
        vm.expectRevert(Receiver.Creation.selector);
        vm.prank(BOOTSTRAP);
        receiver.bootstrap(NUMBER, tokenInit, bad, REVIEW);
        assertUntouched();
    }
}
