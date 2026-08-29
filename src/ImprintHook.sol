// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ImprintHookData } from "./libraries/ImprintHookData.sol";

/// @title Imprint Hook
/// @notice Uniswap v4 hook for refundable price-impact bonds on market-moving swaps.
contract ImprintHook is BaseHook {
    address public immutable trustedRouter;

    error InvalidTrustedRouter();
    error UnauthorizedRouter(address sender);
    error UnexpectedBondToken(address expected, address actual);

    event ProtectedSwapAuthenticated(
        address indexed trader, uint256 indexed nonce, address indexed bondToken, uint256 bondAmount
    );

    constructor(IPoolManager poolManager_, address trustedRouter_) BaseHook(poolManager_) {
        if (trustedRouter_ == address(0)) {
            revert InvalidTrustedRouter();
        }

        trustedRouter = trustedRouter_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        ImprintHookData.ProtectedSwapData memory data = _authenticate(sender, key, params, hookData);

        emit ProtectedSwapAuthenticated(data.trader, data.nonce, data.bondToken, data.bondAmount);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) internal view override returns (bytes4, int128) {
        _authenticate(sender, key, params, hookData);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _authenticate(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        private
        view
        returns (ImprintHookData.ProtectedSwapData memory data)
    {
        if (sender != trustedRouter) {
            revert UnauthorizedRouter(sender);
        }

        data = ImprintHookData.decode(hookData);

        address expectedBondToken = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);

        if (data.bondToken != expectedBondToken) {
            revert UnexpectedBondToken(expectedBondToken, data.bondToken);
        }
    }
}
