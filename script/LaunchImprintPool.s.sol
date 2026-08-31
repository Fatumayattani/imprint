// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { ActionConstants } from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IPoolInitializer_v4 } from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import { IMulticall_v4 } from "@uniswap/v4-periphery/src/interfaces/IMulticall_v4.sol";

/// @title Launch Imprint Pool
/// @notice Initializes the public Imprint USDC/WETH pool and supplies its first full-range liquidity.
contract LaunchImprintPool is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address internal constant IMPRINT_HOOK = 0x58e9eB947696c4EA9A80E65e901162E9BE3E00C0;

    uint24 internal constant LP_FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;

    uint128 internal constant AMOUNT0_MAX = 12_000_000;
    uint128 internal constant AMOUNT1_MAX = 3_000_000_000_000_000;

    // Approximately 4,000 USDC per WETH after accounting for token decimals.
    uint160 internal constant INITIAL_SQRT_PRICE_X96 = 1_252_707_241_875_239_655_932_069_007_848_031;

    // MINT_POSITION followed by CLOSE_CURRENCY for currency0 and currency1.
    // These byte values correspond to the official Actions constants: 0x02, 0x12, 0x12.
    bytes internal constant MINT_AND_CLOSE_ACTIONS = hex"021212";

    error InsufficientTokenBalance(address token, uint256 required, uint256 available);

    function run() external returns (PoolId poolId, uint256 tokenId, uint128 liquidity) {
        address deployer = vm.envAddress("DEPLOYER");

        _requireBalance(deployer, USDC, AMOUNT0_MAX);
        _requireBalance(deployer, WETH, AMOUNT1_MAX);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(IMPRINT_HOOK)
        });

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            INITIAL_SQRT_PRICE_X96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            AMOUNT0_MAX,
            AMOUNT1_MAX
        );

        IPositionManager positionManager = IPositionManager(POSITION_MANAGER);
        tokenId = positionManager.nextTokenId();

        bytes[] memory actionParams = new bytes[](3);

        actionParams[0] = abi.encode(
            key, tickLower, tickUpper, liquidity, AMOUNT0_MAX, AMOUNT1_MAX, ActionConstants.MSG_SENDER, bytes("")
        );

        actionParams[1] = abi.encode(key.currency0);
        actionParams[2] = abi.encode(key.currency1);

        bytes memory liquidityActions = abi.encode(MINT_AND_CLOSE_ACTIONS, actionParams);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, INITIAL_SQRT_PRICE_X96);

        calls[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, liquidityActions, block.timestamp + 30 minutes
        );

        vm.startBroadcast();

        IERC20(USDC).approve(PERMIT2, type(uint256).max);
        IERC20(WETH).approve(PERMIT2, type(uint256).max);

        IAllowanceTransfer(PERMIT2).approve(USDC, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(WETH, POSITION_MANAGER, type(uint160).max, type(uint48).max);

        IMulticall_v4(POSITION_MANAGER).multicall(calls);

        vm.stopBroadcast();

        poolId = key.toId();

        console2.log("Imprint pool launched");
        console2.log("USDC:", USDC);
        console2.log("WETH:", WETH);
        console2.log("Hook:", IMPRINT_HOOK);
        console2.log("Position token ID:", tokenId);
        console2.log("Liquidity:", uint256(liquidity));
        console2.log("Pool ID:");
        console2.logBytes32(PoolId.unwrap(poolId));
    }

    function _requireBalance(address account, address token, uint256 required) private view {
        uint256 available = IERC20(token).balanceOf(account);

        if (available < required) {
            revert InsufficientTokenBalance(token, required, available);
        }
    }
}
