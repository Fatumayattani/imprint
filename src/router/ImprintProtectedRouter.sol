// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { SafeCallback } from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import { DeltaResolver } from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import { ReentrancyLock } from "@uniswap/v4-periphery/src/base/ReentrancyLock.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ImprintHookData } from "../libraries/ImprintHookData.sol";

/// @title Imprint Protected Router
/// @notice Executes authenticated exact-input swaps and escrows their bonds.
contract ImprintProtectedRouter is SafeCallback, DeltaResolver, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    error DeadlineBlockPassed(uint256 deadlineBlock);
    error InvalidAmountIn();
    error InvalidHook();
    error NativeCurrencyNotSupported();
    error TooLittleReceived(uint256 minimum, uint256 received);
    error UnexpectedSwapDelta();
    error BondTransferMismatch(uint256 expected, uint256 received);

    struct ExactInputParams {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        uint256 bondAmount;
        uint256 deadlineBlock;
    }

    struct CallbackData {
        address trader;
        PoolKey key;
        SwapParams swapParams;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    mapping(address trader => uint256 nextNonce) public nonces;

    event ProtectedSwap(
        address indexed trader,
        address indexed hook,
        uint256 indexed nonce,
        address bondToken,
        uint256 bondAmount,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(IPoolManager poolManager_) SafeCallback(poolManager_) { }

    function protectedSwapExactInput(ExactInputParams calldata params)
        external
        isNotLocked
        returns (BalanceDelta delta)
    {
        if (block.number > params.deadlineBlock) {
            revert DeadlineBlockPassed(params.deadlineBlock);
        }
        if (params.amountIn == 0) revert InvalidAmountIn();
        if (address(params.key.hooks) == address(0)) revert InvalidHook();

        address trader = msg.sender;
        Currency inputCurrency = params.zeroForOne ? params.key.currency0 : params.key.currency1;

        address bondToken = Currency.unwrap(inputCurrency);
        if (bondToken == address(0)) {
            revert NativeCurrencyNotSupported();
        }

        uint256 nonce = nonces[trader]++;

        ImprintHookData.ProtectedSwapData memory protectedData = ImprintHookData.ProtectedSwapData({
            trader: trader, bondToken: bondToken, bondAmount: params.bondAmount, nonce: nonce
        });

        bytes memory hookData = ImprintHookData.encode(protectedData);

        _collectBond(bondToken, trader, address(params.key.hooks), params.bondAmount);

        CallbackData memory callbackData = CallbackData({
            trader: trader,
            key: params.key,
            swapParams: SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(uint256(params.amountIn)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
            amountOutMinimum: params.amountOutMinimum,
            hookData: hookData
        });

        delta = abi.decode(poolManager.unlock(abi.encode(callbackData)), (BalanceDelta));

        _emitProtectedSwap(params, trader, nonce, bondToken, delta);
    }

    function _collectBond(address bondToken, address trader, address hook, uint256 bondAmount) private {
        if (bondAmount == 0) return;

        IERC20 token = IERC20(bondToken);
        uint256 balanceBefore = token.balanceOf(hook);
        token.safeTransferFrom(trader, hook, bondAmount);
        uint256 received = token.balanceOf(hook) - balanceBefore;

        if (received != bondAmount) {
            revert BondTransferMismatch(bondAmount, received);
        }
    }

    function _emitProtectedSwap(
        ExactInputParams calldata params,
        address trader,
        uint256 nonce,
        address bondToken,
        BalanceDelta delta
    ) private {
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amountOut = SafeCast.toUint256(int256(outputDelta));

        emit ProtectedSwap(
            trader, address(params.key.hooks), nonce, bondToken, params.bondAmount, params.amountIn, amountOut
        );
    }

    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.swap(data.key, data.swapParams, data.hookData);

        int128 inputDelta = data.swapParams.zeroForOne ? delta.amount0() : delta.amount1();

        int128 outputDelta = data.swapParams.zeroForOne ? delta.amount1() : delta.amount0();

        if (inputDelta >= 0 || outputDelta <= 0) {
            revert UnexpectedSwapDelta();
        }

        uint256 amountIn = SafeCast.toUint256(-int256(inputDelta));
        uint256 amountOut = SafeCast.toUint256(int256(outputDelta));

        if (amountOut < data.amountOutMinimum) {
            revert TooLittleReceived(data.amountOutMinimum, amountOut);
        }

        Currency inputCurrency = data.swapParams.zeroForOne ? data.key.currency0 : data.key.currency1;

        Currency outputCurrency = data.swapParams.zeroForOne ? data.key.currency1 : data.key.currency0;

        _settle(inputCurrency, data.trader, amountIn);
        _take(outputCurrency, data.trader, amountOut);

        return abi.encode(delta);
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        IERC20(Currency.unwrap(token)).safeTransferFrom(payer, address(poolManager), amount);
    }
}
