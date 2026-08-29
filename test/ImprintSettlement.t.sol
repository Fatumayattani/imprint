// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ImprintHook } from "../src/ImprintHook.sol";
import { ImprintProtectedRouter } from "../src/router/ImprintProtectedRouter.sol";

contract ImprintSettlementTest is Deployers {
    using PoolIdLibrary for *;

    ImprintHook internal hook;
    ImprintProtectedRouter internal protectedRouter;

    IERC20 internal token0;
    IERC20 internal token1;

    uint128 internal constant LARGE_AMOUNT_IN = 5e15;
    uint256 internal constant DECLARED_BOND = 1e15;

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

    function largeSwapParams(bool zeroForOne, uint256 bondAmount)
        internal
        view
        returns (ImprintProtectedRouter.ExactInputParams memory params)
    {
        params = ImprintProtectedRouter.ExactInputParams({
            key: key,
            zeroForOne: zeroForOne,
            amountIn: LARGE_AMOUNT_IN,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
            bondAmount: bondAmount,
            deadlineBlock: block.number
        });
    }

    function firstReceiptId() internal view returns (bytes32) {
        return keccak256(abi.encode(key.toId(), address(this), uint256(0)));
    }

    function test_largeSwapCreatesMeasuredBondReceipt() public {
        uint256 creationBlock = block.number;

        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));

        (
            address trader,
            address bondToken,
            PoolId storedPoolId,
            int24 referenceTick,
            int24 impactTick,
            uint64 settleBlock,
            uint64 expiryBlock,
            uint256 declaredBond,
            uint256 requiredBond,
            ImprintHook.ReceiptStatus status
        ) = hook.receipts(firstReceiptId());

        assertEq(trader, address(this));
        assertEq(bondToken, address(token0));
        assertEq(PoolId.unwrap(storedPoolId), PoolId.unwrap(key.toId()));
        assertEq(referenceTick, 0);
        assertGt(referenceTick - impactTick, 50);
        assertEq(settleBlock, creationBlock + hook.OBSERVATION_BLOCKS());
        assertEq(expiryBlock, settleBlock + hook.SETTLEMENT_BLOCKS());
        assertEq(declaredBond, DECLARED_BOND);
        assertGt(requiredBond, 0);
        assertLe(requiredBond, DECLARED_BOND);
        assertEq(uint256(status), uint256(ImprintHook.ReceiptStatus.Pending));
    }

    function test_underbondedSwapRevertsAtomically() public {
        uint256 traderBalanceBefore = token0.balanceOf(address(this));

        vm.expectRevert();

        protectedRouter.protectedSwapExactInput(largeSwapParams(true, 0));

        assertEq(token0.balanceOf(address(this)), traderBalanceBefore);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(protectedRouter.nonces(address(this)), 0);

        (,,,,,,,,, ImprintHook.ReceiptStatus status) = hook.receipts(firstReceiptId());

        assertEq(uint256(status), uint256(ImprintHook.ReceiptStatus.None));
    }

    function receiptState()
        internal
        view
        returns (uint64 settleBlock, uint64 expiryBlock, uint256 requiredBond, ImprintHook.ReceiptStatus status)
    {
        (,,,,, settleBlock, expiryBlock,, requiredBond, status) = hook.receipts(firstReceiptId());
    }

    function test_persistentMovementRefundsEntireDeclaredBond() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        (uint64 settleBlock,,,) = receiptState();
        uint256 traderBalanceBefore = token0.balanceOf(address(this));
        vm.roll(settleBlock);
        hook.settleReceipt(firstReceiptId(), key);
        assertEq(token0.balanceOf(address(this)), traderBalanceBefore + DECLARED_BOND);
        assertEq(token0.balanceOf(address(hook)), 0);
        (,,, ImprintHook.ReceiptStatus status) = receiptState();
        assertEq(uint256(status), uint256(ImprintHook.ReceiptStatus.Settled));
    }

    function test_reversedMovementQueuesRequiredBondForLPs() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        protectedRouter.protectedSwapExactInput(largeSwapParams(false, DECLARED_BOND));
        (uint64 settleBlock,, uint256 requiredBond,) = receiptState();
        uint256 traderBalanceBefore = token0.balanceOf(address(this));
        uint256 managerBalanceBefore = token0.balanceOf(address(manager));
        vm.roll(settleBlock);
        hook.settleReceipt(firstReceiptId(), key);
        assertEq(token0.balanceOf(address(this)), traderBalanceBefore + (DECLARED_BOND - requiredBond));
        assertEq(token0.balanceOf(address(manager)), managerBalanceBefore);
        assertEq(token0.balanceOf(address(hook)), requiredBond);
    }

    function test_expiryForfeitsRequiredBondAndRefundsExcess() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        (, uint64 expiryBlock, uint256 requiredBond,) = receiptState();
        uint256 traderBalanceBefore = token0.balanceOf(address(this));
        uint256 managerBalanceBefore = token0.balanceOf(address(manager));
        vm.roll(uint256(expiryBlock) + 1);
        hook.expireReceipt(firstReceiptId(), key);
        assertEq(token0.balanceOf(address(this)), traderBalanceBefore + (DECLARED_BOND - requiredBond));
        assertEq(token0.balanceOf(address(manager)), managerBalanceBefore);
        (,,, ImprintHook.ReceiptStatus status) = receiptState();
        assertEq(uint256(status), uint256(ImprintHook.ReceiptStatus.Expired));
    }

    function test_enforcesSettlementAndExpiryWindows() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        (uint64 settleBlock, uint64 expiryBlock,,) = receiptState();
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.SettlementTooEarly.selector, block.number, settleBlock));
        hook.settleReceipt(firstReceiptId(), key);
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.ExpiryNotReached.selector, block.number, expiryBlock));
        hook.expireReceipt(firstReceiptId(), key);
        vm.roll(uint256(expiryBlock) + 1);
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.SettlementWindowClosed.selector, block.number, expiryBlock));
        hook.settleReceipt(firstReceiptId(), key);
    }

    function test_cannotFinalizeReceiptTwice() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        (uint64 settleBlock,,,) = receiptState();
        vm.roll(settleBlock);
        hook.settleReceipt(firstReceiptId(), key);
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.ReceiptNotPending.selector, firstReceiptId()));
        hook.settleReceipt(firstReceiptId(), key);
    }

    function test_thirdPartyCanSettleButRefundGoesToTrader() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));

        (uint64 settleBlock,,,) = receiptState();
        address keeper = makeAddr("keeper");
        uint256 traderBalanceBefore = token0.balanceOf(address(this));
        uint256 keeperBalanceBefore = token0.balanceOf(keeper);

        vm.roll(settleBlock);
        vm.prank(keeper);
        hook.settleReceipt(firstReceiptId(), key);

        assertEq(token0.balanceOf(address(this)), traderBalanceBefore + DECLARED_BOND);
        assertEq(token0.balanceOf(keeper), keeperBalanceBefore);
    }

    function test_smallSwapIsIndividuallyBelowThreshold() public {
        ImprintProtectedRouter.ExactInputParams memory params = largeSwapParams(true, 0);
        params.amountIn = 2e15;

        protectedRouter.protectedSwapExactInput(params);

        (,,, int24 referenceTick, int24 impactTick,,,, uint256 requiredBond,) = hook.receipts(firstReceiptId());

        assertLe(int256(referenceTick - impactTick), int256(uint256(hook.IMPACT_THRESHOLD_TICKS())));
        assertEq(requiredBond, 0);
    }

    function receiptIdFor(address trader, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(key.toId(), trader, nonce));
    }

    function test_splitSwapsCannotBypassImpactThreshold() public {
        ImprintProtectedRouter.ExactInputParams memory params = largeSwapParams(true, 0);
        params.amountIn = 2e15;

        protectedRouter.protectedSwapExactInput(params);

        vm.expectRevert();
        protectedRouter.protectedSwapExactInput(params);

        assertEq(protectedRouter.nonces(address(this)), 1);

        (,, uint256 cumulativeNotional, uint256 securedBond) = hook.impactWindows(key.toId(), true);

        assertEq(cumulativeNotional, 2e15);
        assertEq(securedBond, 0);

        params.bondAmount = DECLARED_BOND;
        protectedRouter.protectedSwapExactInput(params);

        (,,,,,,,, uint256 requiredBond,) = hook.receipts(receiptIdFor(address(this), 1));

        assertGt(requiredBond, 0);
        assertEq(protectedRouter.nonces(address(this)), 2);
    }

    function test_splitResistanceIsGlobalAcrossTraders() public {
        ImprintProtectedRouter.ExactInputParams memory params = largeSwapParams(true, 0);
        params.amountIn = 2e15;

        protectedRouter.protectedSwapExactInput(params);

        address alice = makeAddr("splitter");
        deal(address(token0), alice, 3e15);

        vm.startPrank(alice);
        token0.approve(address(protectedRouter), type(uint256).max);

        vm.expectRevert();
        protectedRouter.protectedSwapExactInput(params);
        vm.stopPrank();

        assertEq(protectedRouter.nonces(alice), 0);
        assertEq(protectedRouter.nonces(address(this)), 1);
    }

    function test_impactWindowResetsAfterCooldown() public {
        ImprintProtectedRouter.ExactInputParams memory params = largeSwapParams(true, 0);
        params.amountIn = 2e15;

        protectedRouter.protectedSwapExactInput(params);

        vm.roll(block.number + hook.ACCUMULATION_BLOCKS() + 1);

        params.deadlineBlock = block.number;
        protectedRouter.protectedSwapExactInput(params);

        (, uint64 startBlock, uint256 cumulativeNotional, uint256 securedBond) = hook.impactWindows(key.toId(), true);

        assertEq(startBlock, block.number);
        assertEq(cumulativeNotional, 2e15);
        assertEq(securedBond, 0);
        assertEq(protectedRouter.nonces(address(this)), 2);
    }

    function test_forfeitureIsReleasedInCooldownSlices() public {
        protectedRouter.protectedSwapExactInput(largeSwapParams(true, DECLARED_BOND));
        protectedRouter.protectedSwapExactInput(largeSwapParams(false, DECLARED_BOND));

        (uint64 settleBlock,, uint256 requiredBond,) = receiptState();
        vm.roll(settleBlock);
        hook.settleReceipt(firstReceiptId(), key);

        (uint256 reserve, uint64 lastBlock) = hook.donationStreams(key.toId(), address(token0));
        assertEq(reserve, requiredBond);
        assertEq(lastBlock, settleBlock);

        uint256 nextBlock = uint256(lastBlock) + hook.DONATION_COOLDOWN_BLOCKS();
        vm.expectRevert(abi.encodeWithSelector(ImprintHook.DonationCooldown.selector, block.number, nextBlock));
        hook.dripDonation(key, address(token0));

        vm.roll(nextBlock);
        uint256 managerBefore = token0.balanceOf(address(manager));
        uint256 expectedSlice = requiredBond * hook.DONATION_SLICE_BPS() / 10_000;
        uint256 donated = hook.dripDonation(key, address(token0));

        assertEq(donated, expectedSlice);
        assertEq(token0.balanceOf(address(manager)), managerBefore + expectedSlice);

        (reserve, lastBlock) = hook.donationStreams(key.toId(), address(token0));
        assertEq(reserve, requiredBond - expectedSlice);
        assertEq(lastBlock, block.number);
    }
}
