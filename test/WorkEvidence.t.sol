// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";
import {UnavailableWorkVerifier} from "../src/UnavailableWorkVerifier.sol";
import {IAgentWorkVerifier} from "../src/interfaces/IAgentWorkVerifier.sol";

/// Genuine HTTP bytes and hash bindings; NOT genuine Ethereum inclusion/finality or Robinhood proofs.
contract WorkEvidenceTest is Test {
    function testGenuineDocumentsMatchPublishedCommitmentAndTamperingChangesHash() public view {
        bytes memory work = vm.readFileBinary("test/fixtures/imd-work/work-record.json");
        assertEq(keccak256(work), 0x6e6570b4b0e37c889ed9e12b4656dacfbc56275fd75610bf2655167045ca5146);
        assertEq(
            keccak256(vm.readFileBinary("test/fixtures/imd-work/review.json")),
            0xbc9adaf2bc7436d454d6a94b8ca007ce0fa106e478804743e0828520e567d6db
        );
        assertEq(
            sha256(vm.readFileBinary("test/fixtures/imd-work/artifact.json")),
            0x060ac27ea0eb73c7ebce2b0b83201f20dcaa8f6e831b7390b1f75bf39172c55d
        );
        work[10] = bytes1(uint8(work[10]) ^ 1);
        assertNotEq(keccak256(work), 0x6e6570b4b0e37c889ed9e12b4656dacfbc56275fd75610bf2655167045ca5146);
    }

    function testGenuineJsonAloneCannotAuthorizeProductionRewards() public {
        UnavailableWorkVerifier verifier = new UnavailableWorkVerifier();
        IAgentWorkVerifier.Context memory context;
        IAgentWorkVerifier.Contribution[] memory accepted = new IAgentWorkVerifier.Contribution[](0);
        bytes memory work = vm.readFileBinary("test/fixtures/imd-work/work-record.json");
        vm.expectRevert(UnavailableWorkVerifier.AuthenticatedWorkProofUnavailable.selector);
        verifier.verifyCompleteRound(context, accepted, work);
    }
}
