// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IIMDLaunchRegistry} from "../../src/interfaces/IIMDLaunch.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FINCR} from "../../src/FINCR.sol";

/// @dev TEST MODEL ONLY. Mutable corruption helpers intentionally model bad registry responses.
contract LaunchRegistryMock is IIMDLaunchRegistry {
    mapping(uint64 => Launch) private records;
    mapping(uint64 => Artifact[]) private artifacts;

    function setRecord(uint64 n, Launch memory r) external {
        records[n] = r;
    }

    function setArtifacts(uint64 n, Artifact[] memory a) external {
        delete artifacts[n];
        for (uint256 i; i < a.length; ++i) {
            artifacts[n].push(a[i]);
        }
    }

    function launchOf(uint64 n) external view returns (Launch memory) {
        return records[n];
    }

    function artifactsOf(uint64 n) external view returns (Artifact[] memory) {
        return artifacts[n];
    }
}

/// @dev NOT official IMD code or a claim about its actual salts/order. Interface/predicate rehearsal.
contract ProjectFactoryMock {
    address public immutable registry;
    address public immutable deployer;

    constructor(address r) {
        registry = r;
        deployer = msg.sender;
    }

    function predictToken(uint64 n, bytes memory code) public view returns (address) {
        return _predict(keccak256(abi.encode(n, bytes32("token"))), code);
    }

    function predictContract(uint64 n, uint256 index, bytes memory code) public view returns (address) {
        return _predict(keccak256(abi.encode(n, index)), code);
    }

    function _predict(bytes32 salt, bytes memory code) private view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }

    function launch(
        bytes memory tokenCode,
        bytes memory minerCode,
        IIMDLaunchRegistry.Launch memory r,
        address remainder
    ) external returns (address token, address miner) {
        require(msg.sender == deployer, "mock deployer");
        token = _create(keccak256(abi.encode(r.launchNumber, bytes32("token"))), tokenCode);
        miner = _create(keccak256(abi.encode(r.launchNumber, uint256(0))), minerCode);
        IIMDLaunchRegistry.Artifact[] memory a = new IIMDLaunchRegistry.Artifact[](2);
        a[0] = IIMDLaunchRegistry.Artifact("token", "FINCR", token);
        a[1] = IIMDLaunchRegistry.Artifact("other", "FinancierMiningWithAgents", miner);
        LaunchRegistryMock(registry).setRecord(r.launchNumber, r);
        LaunchRegistryMock(registry).setArtifacts(r.launchNumber, a);
        uint256 supply = IERC20(token).totalSupply();
        // Inventory fixtures only, not actual pools or swarm reward distributors.
        require(IERC20(token).transfer(address(201), supply / 2));
        require(IERC20(token).transfer(address(202), supply / 10));
        require(IERC20(token).transfer(remainder, supply * 2 / 5));
    }

    function _create(bytes32 salt, bytes memory code) private returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0), "mock create failed");
    }
}

/// @dev Malicious local token; never a production FINCR candidate.
contract LaunchTokenMock is FINCR {
    bool public tax;
    address public callback;
    bytes public payload;
    bool public attempted;
    bool public reentered;
    constructor(uint256 supply) FINCR(supply) {}

    function configure(bool tax_, address callback_, bytes memory payload_) external {
        tax = tax_;
        callback = callback_;
        payload = payload_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, tax ? amount - 1 : amount);
        if (tax) _burn(msg.sender, 1);
        if (callback != address(0)) {
            attempted = true;
            (reentered,) = callback.call(payload);
        }
        return result;
    }
}
