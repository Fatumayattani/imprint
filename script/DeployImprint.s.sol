// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ImprintHook } from "../src/ImprintHook.sol";
import { ImprintProtectedRouter } from "../src/router/ImprintProtectedRouter.sol";

contract DeployImprint is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    error PoolManagerHasNoCode(address poolManager);
    error HookAddressMismatch(address expected, address actual);

    function run() external returns (ImprintProtectedRouter router, ImprintHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        if (address(poolManager).code.length == 0) {
            revert PoolManagerHasNoCode(address(poolManager));
        }

        vm.broadcast();
        router = new ImprintProtectedRouter(poolManager);

        bytes memory constructorArgs = abi.encode(poolManager, address(router));

        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(ImprintHook).creationCode, constructorArgs);

        vm.broadcast();
        hook = new ImprintHook{ salt: salt }(poolManager, address(router));

        if (address(hook) != expectedHookAddress) {
            revert HookAddressMismatch(expectedHookAddress, address(hook));
        }

        console2.log("PoolManager:", address(poolManager));
        console2.log("ImprintProtectedRouter:", address(router));
        console2.log("ImprintHook:", address(hook));
        console2.logBytes32(salt);
    }
}
