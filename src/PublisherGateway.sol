// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RobinhoodJobController} from "./RobinhoodJobController.sol";
import {AttestedAgentRounds} from "./AttestedAgentRounds.sol";
import {IAgentWorkVerifier} from "./interfaces/IAgentWorkVerifier.sol";

/// @notice TASK30 PROTOTYPE, not approved production authority. No custody or arbitrary calls.
/// @dev Operator retains the controller publisher's trusted evidence powers over the agent 20%.
contract PublisherGateway {
    address public constant FOUNDER = 0xbcF19c0821A245383c127570615896Abac9e424F;
    address public constant OPERATIONS = 0x74421cdb9e6ad159358c4af7C59CFAE472A0541e;
    address public operator;
    RobinhoodJobController public controller;
    bytes32 public controllerCodeHash;
    bool public paused = true;
    error Unauthorized();
    error InvalidConfiguration();
    error Unavailable();
    event ControllerBound(address indexed controller, bytes32 codeHash);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator);
    event PauseChanged(bool paused);
    event Forwarded(bytes4 indexed selector, uint256 indexed roundId, address indexed operator, bytes32 calldataHash);

    constructor(address operator_) {
        if (block.chainid != 4663 || msg.sender != FOUNDER) revert Unauthorized();
        _setOperator(operator_);
    }

    modifier founderOnly() {
        if (block.chainid != 4663 || msg.sender != FOUNDER) revert Unauthorized();
        _;
    }

    modifier forwarding(uint256 roundId) {
        if (block.chainid != 4663 || msg.sender != operator) revert Unauthorized();
        if (paused || address(controller) == address(0) || address(controller).codehash != controllerCodeHash) {
            revert Unavailable();
        }
        _;
        emit Forwarded(msg.sig, roundId, msg.sender, keccak256(msg.data));
    }

    /// @notice Founder independently verifies exact source, constructor and runtime before binding.
    /// Hash is provided explicitly for a reviewable transaction; getters alone do not prove source.
    function bindController(RobinhoodJobController candidate, bytes32 expectedRuntimeHash) external founderOnly {
        if (
            address(controller) != address(0) || address(candidate).code.length == 0 || expectedRuntimeHash == 0
                || address(candidate).codehash != expectedRuntimeHash || candidate.publisher() != address(this)
                || candidate.initializer() != FOUNDER || address(candidate.miner()) != address(0)
        ) revert InvalidConfiguration();
        controller = candidate;
        controllerCodeHash = expectedRuntimeHash;
        emit ControllerBound(address(candidate), expectedRuntimeHash);
    }

    function setPaused(bool value) external founderOnly {
        paused = value;
        emit PauseChanged(value);
    }

    /// Rotation always pauses; founder must review the replacement before explicitly resuming.
    function replaceOperator(address replacement) external founderOnly {
        _setOperator(replacement);
        paused = true;
        emit PauseChanged(true);
    }

    function _setOperator(address replacement) private {
        if (
            replacement == address(0) || replacement == FOUNDER || replacement == OPERATIONS
                || replacement == address(this) || replacement.code.length != 0 || replacement == operator
        ) {
            revert InvalidConfiguration();
        }
        address previous = operator;
        operator = replacement;
        emit OperatorChanged(previous, replacement);
    }

    function bindJob(uint256 roundId, AttestedAgentRounds.Admission calldata admission) external forwarding(roundId) {
        controller.bindJob(roundId, admission);
    }

    function lockSnapshot(uint256 roundId, AttestedAgentRounds.Snapshot calldata snapshot)
        external
        forwarding(roundId)
    {
        controller.lockSnapshot(roundId, snapshot);
    }

    function finalizeRound(
        uint256 roundId,
        IAgentWorkVerifier.Contribution[] calldata accepted,
        AttestedAgentRounds.Snapshot calldata snapshot,
        AttestedAgentRounds.OwnerEvidence[] calldata owners,
        bytes32 expectedCommitment
    ) external forwarding(roundId) {
        controller.finalizeRound(roundId, accepted, snapshot, owners, expectedCommitment);
    }
}
