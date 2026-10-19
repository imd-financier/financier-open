// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Source-reference ABI from HMM's pinned IMD interface, NOT verified Robinhood runtime.
/// Deployment is blocked until these selectors, writers and prediction semantics are verified.
interface IIMDLaunchRegistry {
    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct Artifact {
        bytes32 role;
        bytes32 name;
        address addr;
    }
    function launchOf(uint64 number) external view returns (Launch memory);
    function artifactsOf(uint64 number) external view returns (Artifact[] memory);
}

interface IIMDProjectFactory {
    function registry() external view returns (address);
    function deployer() external view returns (address);
    function predictToken(uint64 number, bytes calldata creationCode) external view returns (address);
    function predictContract(uint64 number, uint256 index, bytes calldata creationCode) external view returns (address);
}
