// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { FeeOnTransferToken } from "./mocks/FeeOnTransferToken.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ImprintHook } from "../src/ImprintHook.sol";
import { ImprintProtectedRouter } from "../src/router/ImprintProtectedRouter.sol";

contract ImprintProtectedRouterTest is Deployers {
    ImprintHook internal hook;
    ImprintProtectedRouter internal protectedRouter;

    IERC20 internal token0;
    IERC20 internal token1;

    uint160 internal constant EXPECTED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUp() public {
        deployFreshManagerAndRouters();

        protectedRouter = new ImprintProtectedRouter(manager);

        bytes memory constructorArgs = abi.encode(manager, address(protectedRouter));

        (, bytes32 salt) =
            HookMiner.find(address(this), EXPECTED_FLAGS, type(ImprintHook).creationCode, constructorArgs);

        hook = new ImprintHook{ salt: salt }(manager, address(protectedRouter));

        deployMintAndApprove2Currencies();

        token0 = IERC20(Currency.unwrap(currency0));
        token1 = IERC20(Currency.unwrap(currency1));

        token0.approve(address(protectedRouter), type(uint256).max);
        token1.approve(address(protectedRouter), type(uint256).max);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function exactInputParams(bool zeroForOne, uint256 bondAmount)
        internal
        view
        returns (ImprintProtectedRouter.ExactInputParams memory params)
    {
        params = ImprintProtectedRouter.ExactInputParams({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: 1e15,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
            bondAmount: bondAmount,
            deadlineBlock: block.number
        });
    }

    function test_executesZeroForOneThroughRealPoolManager() public {
        uint256 bondAmount = 1e13;
        uint256 hookBondBefore = token0.balanceOf(address(hook));
        uint256 outputBefore = token1.balanceOf(address(this));

        protectedRouter.protectedSwapExactInput(exactInputParams(true, bondAmount));

        assertEq(token0.balanceOf(address(hook)), hookBondBefore + bondAmount);
        assertGt(token1.balanceOf(address(this)), outputBefore);
        assertEq(protectedRouter.nonces(address(this)), 1);
    }

    function test_executesOneForZeroAndUsesToken1Bond() public {
        uint256 bondAmount = 2e13;
        uint256 hookBondBefore = token1.balanceOf(address(hook));
        uint256 outputBefore = token0.balanceOf(address(this));

        protectedRouter.protectedSwapExactInput(exactInputParams(false, bondAmount));

        assertEq(token1.balanceOf(address(hook)), hookBondBefore + bondAmount);
        assertGt(token0.balanceOf(address(this)), outputBefore);
        assertEq(protectedRouter.nonces(address(this)), 1);
    }

    function test_allowsZeroBondForBelowThresholdSwap() public {
        protectedRouter.protectedSwapExactInput(exactInputParams(true, 0));

        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(protectedRouter.nonces(address(this)), 1);
    }

    function test_nonceIncrementsAcrossProtectedSwaps() public {
        protectedRouter.protectedSwapExactInput(exactInputParams(true, 1e12));
        protectedRouter.protectedSwapExactInput(exactInputParams(false, 1e12));

        assertEq(protectedRouter.nonces(address(this)), 2);
    }

    function test_attributesSwapAndNonceToOriginalTrader() public {
        address alice = makeAddr("alice");
        uint256 bondAmount = 1e13;

        deal(address(token0), alice, 2e15);

        vm.startPrank(alice);
        token0.approve(address(protectedRouter), type(uint256).max);
        uint256 outputBefore = token1.balanceOf(alice);

        protectedRouter.protectedSwapExactInput(exactInputParams(true, bondAmount));
        vm.stopPrank();

        assertGt(token1.balanceOf(alice), outputBefore);
        assertEq(protectedRouter.nonces(alice), 1);
        assertEq(protectedRouter.nonces(address(this)), 0);
        assertEq(token0.balanceOf(address(hook)), bondAmount);
    }

    function test_minimumOutputFailureRevertsBondAndNonce() public {
        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1e13);

        params.amountOutMinimum = type(uint128).max;

        uint256 hookBalanceBefore = token0.balanceOf(address(hook));

        vm.expectPartialRevert(ImprintProtectedRouter.TooLittleReceived.selector);
        protectedRouter.protectedSwapExactInput(params);

        assertEq(token0.balanceOf(address(hook)), hookBalanceBefore);
        assertEq(protectedRouter.nonces(address(this)), 0);
    }

    function test_rejectsExpiredDeadlineBlock() public {
        vm.roll(100);

        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1e13);

        params.deadlineBlock = 99;

        vm.expectRevert(abi.encodeWithSelector(ImprintProtectedRouter.DeadlineBlockPassed.selector, 99));
        protectedRouter.protectedSwapExactInput(params);
    }

    function test_rejectsZeroInput() public {
        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1e13);

        params.amountIn = 0;

        vm.expectRevert(ImprintProtectedRouter.InvalidAmountIn.selector);
        protectedRouter.protectedSwapExactInput(params);
    }

    function test_rejectsPoolWithoutHook() public {
        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1e13);

        params.key.hooks = IHooks(address(0));

        vm.expectRevert(ImprintProtectedRouter.InvalidHook.selector);
        protectedRouter.protectedSwapExactInput(params);
    }

    function test_rejectsNativeInputBond() public {
        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1e13);

        params.key.currency0 = CurrencyLibrary.ADDRESS_ZERO;

        vm.expectRevert(ImprintProtectedRouter.NativeCurrencyNotSupported.selector);
        protectedRouter.protectedSwapExactInput(params);
    }

    function test_rejectsFeeOnTransferBondToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(address(this), 2 ether);
        feeToken.approve(address(protectedRouter), type(uint256).max);

        ImprintProtectedRouter.ExactInputParams memory params = exactInputParams(true, 1 ether);
        params.key.currency0 = Currency.wrap(address(feeToken));

        vm.expectRevert(
            abi.encodeWithSelector(ImprintProtectedRouter.BondTransferMismatch.selector, 1 ether, 0.99 ether)
        );
        protectedRouter.protectedSwapExactInput(params);

        assertEq(feeToken.balanceOf(address(hook)), 0);
        assertEq(protectedRouter.nonces(address(this)), 0);
    }
}
