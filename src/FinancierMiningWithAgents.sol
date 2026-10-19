// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {FinancierMining} from "./FinancierMining.sol";
import {AgentRounds} from "./AgentRounds.sol";

/// @notice Locally integrated variant; real attribution still requires a verified proof adapter.
/// Twelve static app words fit the published custom-token <=16-word schema.
contract FinancierMiningWithAgents is FinancierMining {
    AgentRounds public immutable agentRounds;

    constructor(
        address fincr_,
        address imd_,
        uint256 supply_,
        uint256 initialQuote_,
        uint256 floor_,
        address initializer_,
        address operationsRecipient_,
        address verifier_,
        bytes32 policy_,
        uint256 roundSeconds_,
        uint256 graceSeconds_,
        uint256 identityMaxAge_
    ) FinancierMining(fincr_, imd_, supply_, initialQuote_, floor_, initializer_, operationsRecipient_) {
        agentRounds = new AgentRounds(address(this), verifier_, policy_, roundSeconds_, graceSeconds_, identityMaxAge_);
    }

    function agentController() public view override returns (address) {
        return address(agentRounds);
    }
}
