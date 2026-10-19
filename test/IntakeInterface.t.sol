// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IntegrationBase} from "./helpers/IntegrationBase.sol";
import {IIMDIntake} from "../src/interfaces/IIMDIntake.sol";

/// Test-only request decoder. Does not assert the real Intake's payment or callback behavior.
contract IntakeCodecMock is IIMDIntake {
    bytes32 public binding;

    function request(bytes32 action, bytes calldata body, Callback calldata cb, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        return _record(action, body, cb, bytes4(0), asset, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external returns (bytes32) {
        return _record(action, body, cb, failure, asset, amount);
    }

    function _record(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 failure,
        address asset,
        uint256 amount
    ) private returns (bytes32) {
        binding = keccak256(abi.encode(msg.sender, action, body, cb, failure, asset, amount));
        return binding;
    }
}

contract IntakeInterfaceTest is IntegrationBase {
    function testPublishedAbiEncodingAndCallbackBinding() public {
        IIMDIntake intake = new IntakeCodecMock();
        IIMDIntake.Callback memory cb = IIMDIntake.Callback(address(this), bytes4(keccak256("complete(bytes32,bytes)")));
        bytes memory body = bytes('{"round":0,"project":"FINANCIER","expectedWorkHash":"LOCAL_MOCK_ONLY"}');
        bytes4 failure = bytes4(keccak256("failed(bytes32,bytes)"));
        bytes32 result =
            intake.requestWithFailure(bytes32("job.open@job-1"), body, cb, failure, address(123), 0.5 ether);
        assertEq(
            result,
            keccak256(
                abi.encode(
                    address(this), bytes32("job.open@job-1"), body, cb, failure, address(123), uint256(0.5 ether)
                )
            )
        );
        assertEq(
            IIMDIntake.request.selector, bytes4(keccak256("request(bytes32,bytes,(address,bytes4),address,uint256)"))
        );
        assertEq(
            IIMDIntake.requestWithFailure.selector,
            bytes4(keccak256("requestWithFailure(bytes32,bytes,(address,bytes4),bytes4,address,uint256)"))
        );
    }

    function testNoWorkBudgetSpenderAllowanceOrGenericExecutor() public {
        deployIntegration(false);
        forwardAndStart();
        uint256 work = miner.workBudget();
        IntakeCodecMock intake = new IntakeCodecMock();
        assertEq(imd.allowance(address(miner), address(intake)), 0);
        (bool ok,) = address(miner).call(abi.encodeWithSignature("dispatch(uint256,bytes)", 0, bytes("unrelated job")));
        assertFalse(ok);
        (ok,) = address(miner).call(abi.encodeWithSignature("execute(address,bytes)", address(intake), bytes("")));
        assertFalse(ok);
        assertEq(miner.workBudget(), work);
        assertEq(imd.balanceOf(address(miner)), miner.imdLiability());
    }
}
