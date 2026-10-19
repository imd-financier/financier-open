// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

/// @notice Explicit fail-closed adapter while genuine source-to-Robinhood proof is unavailable.
/// No signer, owner, setter or bypass. Local generated acceptances belong only in test mocks.
contract UnavailableWorkVerifier is IAgentWorkVerifier {
    error AuthenticatedWorkProofUnavailable();

    function verifyCompleteRound(Context calldata, Contribution[] calldata, bytes calldata)
        external
        pure
        returns (bytes32)
    {
        revert AuthenticatedWorkProofUnavailable();
    }
}
