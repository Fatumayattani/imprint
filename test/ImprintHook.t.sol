// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { ImprintHookData } from "../src/libraries/ImprintHookData.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ImprintHook } from "../src/ImprintHook.sol";
import { ImprintProtectedRouter } from "../src/router/ImprintProtectedRouter.sol";

contract ImprintHookTest is Deployers {
    ImprintHook internal hook;
    ImprintProtectedRouter internal protectedRouter;

    uint160 internal constant EXPECTED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();

        protectedRouter = new ImprintProtectedRouter(manager);

        bytes memory constructorArgs = abi.encode(manager, address(protectedRouter));

        (address expectedAddress, bytes32 salt) =
            HookMiner.find(address(this), EXPECTED_FLAGS, type(ImprintHook).creationCode, constructorArgs);

        hook = new ImprintHook{ salt: salt }(manager, address(protectedRouter));

        assertEq(address(hook), expectedAddress);

        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_hookUsesRealPoolManagerAndTrustedRouter() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.trustedRouter(), address(protectedRouter));
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

    function test_rejectsUnexpectedBondToken() public {
        ImprintHookData.ProtectedSwapData memory data = ImprintHookData.ProtectedSwapData({
            trader: address(this), bondToken: Currency.unwrap(currency1), bondAmount: 1e13, nonce: 0
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ImprintHook.UnexpectedBondToken.selector, Currency.unwrap(currency0), Currency.unwrap(currency1)
            )
        );

        vm.prank(address(manager));
        hook.beforeSwap(address(protectedRouter), key, SWAP_PARAMS, ImprintHookData.encode(data));
    }

    function test_rejectsSwapFromUntrustedRouter() public {
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.UnauthorizedRouter.selector, address(swapRouter)));

        vm.prank(address(manager));
        hook.beforeSwap(address(swapRouter), key, SWAP_PARAMS, ZERO_BYTES);
    }
}
