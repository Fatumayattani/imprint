// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ImprintHook } from "../src/ImprintHook.sol";

contract ImprintHookTest is Deployers {
    ImprintHook internal hook;

    uint160 internal constant EXPECTED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUp() public {
        // Deploy the real Uniswap v4 PoolManager and official test routers.
        deployFreshManagerAndRouters();

        // Mine an address whose low bits encode Imprint's hook permissions.
        (address expectedAddress, bytes32 salt) =
            HookMiner.find(address(this), EXPECTED_FLAGS, type(ImprintHook).creationCode, abi.encode(manager));

        hook = new ImprintHook{ salt: salt }(manager);
        assertEq(address(hook), expectedAddress);

        // Deploy disposable test currencies, initialize a real v4 pool,
        // and provide liquidity through Uniswap's official router.
        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_hookUsesRealPoolManager() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(key.hooks), address(hook));
    }

    function test_hookAddressEncodesDeclaredPermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS);
    }

    function test_declaresOnlySwapObservationPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    function test_swapExecutesThroughRealPoolManagerAndHook() public {
        swap(key, true, -1e15, ZERO_BYTES);
    }
}
