// ABI reference: deep-pond-dev/hmm 01d59b2e769ff22f2a67ce3466f568af8aee3bac (MIT).
// launchCustom selector independently matched to actual Robinhood launch transaction.
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IIMDLaunchRegistry as ILaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";

/// @notice The IMD ProjectFactory (Ethereum mainnet 0xff03410d0fe5fa8f7f59f743de35e333d9857120) as far as a
/// `custom_token` launch goes. Only the factory's `deployer()` (the swarm's launch wallet) may call `launchCustom`;
/// fork tests and the devnet impersonate it to rehearse a launch exactly as the swarm runs it.
interface IProjectFactory {
    struct CustomParams {
        uint64 launchNumber;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        ILaunchRegistry.Launch record;
        uint256[] agentIds;
        address requester;
    }

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function launchCustom(CustomParams calldata p)
        external
        returns (address token, address[] memory contracts, address distributor);

    function deployer() external view returns (address);

    function registry() external view returns (address);

    function predictToken(uint64 launchNumber, bytes calldata code) external view returns (address);

    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);

    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, address requester);

    function setRequester(uint64 launchNumber, address next) external;

    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);

    function owed(address account, address currency) external view returns (uint256);
}
