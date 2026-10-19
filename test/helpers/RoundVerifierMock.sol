// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IAgentWorkVerifier} from "../../src/interfaces/IAgentWorkVerifier.sol";

/// @dev Generated test fixture approval, NOT an authenticated IMD signer or production adapter.
/// Test authority can revoke/change a mock proof, modeling a verifier that checks current authority.
contract RoundVerifierMock is IAgentWorkVerifier {
    mapping(bytes32 => bytes32) public approved;

    function approve(bytes32 proofId, bytes32 digest) external {
        approved[proofId] = digest;
    }

    function verifyCompleteRound(Context calldata c, Contribution[] calldata a, bytes calldata proof)
        external
        view
        returns (bytes32)
    {
        require(proof.length == 32, "mock proof length");
        bytes32 digest = keccak256(abi.encode(c, a));
        require(approved[abi.decode(proof, (bytes32))] == digest, "mock missing/revoked proof");
        return digest;
    }
}
