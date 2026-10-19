// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Test} from "forge-std/Test.sol";

/// Genuine RPC receipt/document linkage. NOT a receipt trie proof or a Robinhood verifier.
contract ReceiptEvidenceTest is Test {
    function testActualEthereumReceiptCommitsGenuineWorkDocument() public view {
        string memory j = vm.readFile("test/fixtures/real-chain/work-receipt.json");
        assertEq(vm.parseJsonBytes32(j, ".receipt.blockHash"), vm.parseJsonBytes32(j, ".receiptBlock.hash"));
        assertEq(vm.parseJsonBytes32(j, ".receipt.transactionHash"), vm.parseJsonBytes32(j, ".transaction.hash"));
        assertEq(vm.parseJsonString(j, ".receipt.status"), "0x1");
        address registry = address(bytes20(hex"b6d0a187b050fa5bb0b87033a203f37becf4a775"));
        assertEq(vm.parseJsonAddress(j, ".receipt.to"), registry);
        assertEq(vm.parseJsonAddress(j, ".receipt.logs[5].address"), registry);
        assertEq(
            vm.parseJsonBytes32(j, ".receipt.logs[5].topics[1]"),
            0x3d7ff049144740768e84635c42acf5e000000000000000000000000000000000
        );
        assertEq(
            vm.parseJsonBytes32(j, ".receipt.logs[5].topics[2]"),
            keccak256(vm.readFileBinary("test/fixtures/imd-work/work-record.json"))
        );
        assertEq(uint256(vm.parseJsonBytes32(j, ".receipt.logs[3].topics[1]")), 51073);
        bytes memory feedback = vm.parseJsonBytes(j, ".receipt.logs[3].data");
        // ERC-8004 NewFeedback data: index,value,decimals,tag1 offset,tag2 offset,endpoint offset,URI offset,feedbackHash.
        bytes32 committedReview;
        assembly { committedReview := mload(add(feedback, 256)) }
        assertEq(committedReview, keccak256(vm.readFileBinary("test/fixtures/imd-work/review.json")));
    }
}
