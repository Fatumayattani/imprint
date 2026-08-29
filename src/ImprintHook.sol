// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ImpactBondMath } from "./libraries/ImpactBondMath.sol";
import { ImprintHookData } from "./libraries/ImprintHookData.sol";

/// @title Imprint Hook
/// @notice Refundable price-impact bonds for Uniswap v4 swaps.
contract ImprintHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint24 public constant IMPACT_THRESHOLD_TICKS = 50;
    uint16 public constant BASE_BOND_BPS = 100;
    uint16 public constant SLOPE_BPS_PER_TICK = 10;
    uint16 public constant MAX_BOND_BPS = 2_000;

    uint64 public constant OBSERVATION_BLOCKS = 20;
    uint64 public constant SETTLEMENT_BLOCKS = 100;
    uint64 public constant ACCUMULATION_BLOCKS = 5;
    uint64 public constant DONATION_COOLDOWN_BLOCKS = 5;
    uint16 public constant DONATION_SLICE_BPS = 1_000;

    address public immutable trustedRouter;

    enum ReceiptStatus {
        None,
        Pending,
        Settled,
        Expired
    }

    struct BondReceipt {
        address trader;
        address bondToken;
        PoolId poolId;
        int24 referenceTick;
        int24 impactTick;
        uint64 settleBlock;
        uint64 expiryBlock;
        uint256 declaredBond;
        uint256 requiredBond;
        ReceiptStatus status;
    }

    struct PendingObservation {
        int24 referenceTick;
        bool active;
    }

    struct PoolImpactWindow {
        int24 anchorTick;
        uint64 startBlock;
        uint256 cumulativeNotional;
        uint256 securedBond;
    }

    struct DonationStream {
        uint256 reserve;
        uint64 lastDonationBlock;
    }

    struct DonationData {
        PoolKey key;
        address bondToken;
        uint256 amount;
    }

    mapping(bytes32 receiptId => BondReceipt receipt) public receipts;

    mapping(bytes32 receiptId => PendingObservation observation) private pendingObservations;

    mapping(PoolId poolId => mapping(bool zeroForOne => PoolImpactWindow window)) public impactWindows;
    mapping(PoolId poolId => mapping(address bondToken => DonationStream stream)) public donationStreams;

    error InvalidTrustedRouter();
    error UnauthorizedRouter(address sender);
    error UnexpectedBondToken(address expected, address actual);
    error ExactInputOnly();
    error DuplicateReceipt(bytes32 receiptId);
    error MissingObservation(bytes32 receiptId);
    error InsufficientBond(uint256 required, uint256 declared);
    error ReceiptNotFound(bytes32 receiptId);
    error ReceiptNotPending(bytes32 receiptId);
    error SettlementTooEarly(uint256 currentBlock, uint256 settleBlock);
    error SettlementWindowClosed(uint256 currentBlock, uint256 expiryBlock);
    error ExpiryNotReached(uint256 currentBlock, uint256 expiryBlock);
    error PoolKeyMismatch(PoolId expected, PoolId actual);
    error NoDonationReserve(PoolId poolId, address bondToken);
    error DonationCooldown(uint256 currentBlock, uint256 nextBlock);
    error InvalidDonationToken(address bondToken);

    event DonationQueued(PoolId indexed poolId, address indexed bondToken, uint256 amount, uint256 reserve);

    event DonationDripped(PoolId indexed poolId, address indexed bondToken, uint256 amount, uint256 remainingReserve);

    event ImpactWindowUpdated(
        PoolId indexed poolId,
        bool indexed zeroForOne,
        int24 anchorTick,
        int24 currentTick,
        uint256 cumulativeNotional,
        uint256 aggregateRequiredBond,
        uint256 marginalRequiredBond
    );

    event BondReceiptCreated(
        bytes32 indexed receiptId,
        address indexed trader,
        PoolId indexed poolId,
        address bondToken,
        uint256 declaredBond,
        uint256 requiredBond,
        int24 referenceTick,
        int24 impactTick,
        uint256 settleBlock,
        uint256 expiryBlock
    );

    event BondReceiptFinalized(
        bytes32 indexed receiptId, ReceiptStatus status, uint256 persistenceBps, uint256 refund, uint256 lpDonation
    );

    constructor(IPoolManager poolManager_, address trustedRouter_) BaseHook(poolManager_) {
        if (trustedRouter_ == address(0)) {
            revert InvalidTrustedRouter();
        }

        trustedRouter = trustedRouter_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    function receiptId(PoolId poolId, address trader, uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, trader, nonce));
    }

    function bondCurve() public pure returns (ImpactBondMath.BondCurve memory) {
        return ImpactBondMath.BondCurve({
            thresholdTicks: IMPACT_THRESHOLD_TICKS,
            baseBondBps: BASE_BOND_BPS,
            slopeBpsPerTick: SLOPE_BPS_PER_TICK,
            maxBondBps: MAX_BOND_BPS
        });
    }

    function dripDonation(PoolKey calldata key, address bondToken) external returns (uint256 amount) {
        PoolId poolId = key.toId();

        bool isCurrency0 = Currency.unwrap(key.currency0) == bondToken;
        bool isCurrency1 = Currency.unwrap(key.currency1) == bondToken;

        if (!isCurrency0 && !isCurrency1) {
            revert InvalidDonationToken(bondToken);
        }

        DonationStream storage stream = donationStreams[poolId][bondToken];

        if (stream.reserve == 0) {
            revert NoDonationReserve(poolId, bondToken);
        }

        uint256 nextBlock = uint256(stream.lastDonationBlock) + DONATION_COOLDOWN_BLOCKS;

        if (block.number < nextBlock) {
            revert DonationCooldown(block.number, nextBlock);
        }

        (amount,) = ImpactBondMath.settlementAmounts(stream.reserve, DONATION_SLICE_BPS);

        if (amount == 0) amount = 1;

        stream.reserve -= amount;
        stream.lastDonationBlock = block.number.toUint64();

        poolManager.unlock(abi.encode(DonationData({ key: key, bondToken: bondToken, amount: amount })));

        emit DonationDripped(poolId, bondToken, amount, stream.reserve);
    }

    function settleReceipt(bytes32 id, PoolKey calldata key) external {
        BondReceipt storage receipt = receipts[id];

        _requirePendingReceipt(id, receipt);
        _validatePoolKey(receipt, key);

        if (block.number < receipt.settleBlock) {
            revert SettlementTooEarly(block.number, receipt.settleBlock);
        }

        if (block.number > receipt.expiryBlock) {
            revert SettlementWindowClosed(block.number, receipt.expiryBlock);
        }

        (, int24 settlementTick,,) = poolManager.getSlot0(receipt.poolId);

        uint16 persistedBps = ImpactBondMath.persistenceBps(receipt.referenceTick, receipt.impactTick, settlementTick);

        _finalize(id, receipt, persistedBps, ReceiptStatus.Settled);
    }

    function expireReceipt(bytes32 id, PoolKey calldata key) external {
        BondReceipt storage receipt = receipts[id];

        _requirePendingReceipt(id, receipt);
        _validatePoolKey(receipt, key);

        if (block.number <= receipt.expiryBlock) {
            revert ExpiryNotReached(block.number, receipt.expiryBlock);
        }

        _finalize(id, receipt, 0, ReceiptStatus.Expired);
    }

    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        DonationData memory data = abi.decode(rawData, (DonationData));

        bool bondIsCurrency0 = Currency.unwrap(data.key.currency0) == data.bondToken;

        uint256 amount0 = bondIsCurrency0 ? data.amount : 0;
        uint256 amount1 = bondIsCurrency0 ? 0 : data.amount;

        BalanceDelta delta = poolManager.donate(data.key, amount0, amount1, "");

        Currency bondCurrency = bondIsCurrency0 ? data.key.currency0 : data.key.currency1;

        poolManager.sync(bondCurrency);

        IERC20(data.bondToken).safeTransfer(address(poolManager), data.amount);

        poolManager.settle();

        return abi.encode(delta);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        ImprintHookData.ProtectedSwapData memory data = _authenticate(sender, key, params, hookData);

        if (params.amountSpecified >= 0) revert ExactInputOnly();

        bytes32 id = receiptId(key.toId(), data.trader, data.nonce);

        if (receipts[id].status != ReceiptStatus.None || pendingObservations[id].active) {
            revert DuplicateReceipt(id);
        }

        (, int24 referenceTick,,) = poolManager.getSlot0(key.toId());

        pendingObservations[id] = PendingObservation({ referenceTick: referenceTick, active: true });

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        ImprintHookData.ProtectedSwapData memory data = _authenticate(sender, key, params, hookData);

        bytes32 id = receiptId(key.toId(), data.trader, data.nonce);

        PendingObservation memory observation = pendingObservations[id];

        if (!observation.active) {
            revert MissingObservation(id);
        }

        delete pendingObservations[id];

        (, int24 impactTick,,) = poolManager.getSlot0(key.toId());

        _storeReceipt(id, key, params, data, observation.referenceTick, impactTick);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _storeReceipt(
        bytes32 id,
        PoolKey calldata key,
        SwapParams calldata params,
        ImprintHookData.ProtectedSwapData memory data,
        int24 referenceTick,
        int24 impactTick
    ) private {
        uint256 notional = SafeCast.toUint256(-params.amountSpecified);

        (uint256 requiredBond, int24 anchorTick) =
            _updateImpactWindow(key.toId(), params.zeroForOne, referenceTick, impactTick, notional);

        if (data.bondAmount < requiredBond) {
            revert InsufficientBond(requiredBond, data.bondAmount);
        }

        BondReceipt storage receipt = receipts[id];
        receipt.trader = data.trader;
        receipt.bondToken = data.bondToken;
        receipt.poolId = key.toId();
        receipt.referenceTick = anchorTick;
        receipt.impactTick = impactTick;
        receipt.settleBlock = (block.number + OBSERVATION_BLOCKS).toUint64();
        receipt.expiryBlock = (uint256(receipt.settleBlock) + SETTLEMENT_BLOCKS).toUint64();
        receipt.declaredBond = data.bondAmount;
        receipt.requiredBond = requiredBond;
        receipt.status = ReceiptStatus.Pending;

        _emitReceiptCreated(id, receipt);
    }

    function _updateImpactWindow(
        PoolId poolId,
        bool zeroForOne,
        int24 referenceTick,
        int24 currentTick,
        uint256 notional
    ) private returns (uint256 marginalRequiredBond, int24 anchorTick) {
        PoolImpactWindow storage window = impactWindows[poolId][zeroForOne];

        if (window.cumulativeNotional == 0 || block.number > uint256(window.startBlock) + ACCUMULATION_BLOCKS) {
            window.anchorTick = referenceTick;
            window.startBlock = block.number.toUint64();
            window.cumulativeNotional = 0;
            window.securedBond = 0;
        }

        window.cumulativeNotional += notional;
        anchorTick = window.anchorTick;

        uint24 cumulativeImpactTicks = ImpactBondMath.tickDistance(anchorTick, currentTick);

        uint256 aggregateRequiredBond =
            ImpactBondMath.bondAmount(window.cumulativeNotional, cumulativeImpactTicks, bondCurve());

        if (aggregateRequiredBond > window.securedBond) {
            marginalRequiredBond = aggregateRequiredBond - window.securedBond;
            window.securedBond = aggregateRequiredBond;
        }

        emit ImpactWindowUpdated(
            poolId,
            zeroForOne,
            anchorTick,
            currentTick,
            window.cumulativeNotional,
            aggregateRequiredBond,
            marginalRequiredBond
        );
    }

    function _queueDonation(PoolId poolId, address bondToken, uint256 amount) private {
        DonationStream storage stream = donationStreams[poolId][bondToken];

        if (stream.reserve == 0) {
            stream.lastDonationBlock = block.number.toUint64();
        }

        stream.reserve += amount;

        emit DonationQueued(poolId, bondToken, amount, stream.reserve);
    }

    function _emitReceiptCreated(bytes32 id, BondReceipt storage receipt) private {
        emit BondReceiptCreated(
            id,
            receipt.trader,
            receipt.poolId,
            receipt.bondToken,
            receipt.declaredBond,
            receipt.requiredBond,
            receipt.referenceTick,
            receipt.impactTick,
            receipt.settleBlock,
            receipt.expiryBlock
        );
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

    function _requirePendingReceipt(bytes32 id, BondReceipt storage receipt) private view {
        if (receipt.status == ReceiptStatus.None) {
            revert ReceiptNotFound(id);
        }

        if (receipt.status != ReceiptStatus.Pending) {
            revert ReceiptNotPending(id);
        }
    }

    function _validatePoolKey(BondReceipt storage receipt, PoolKey calldata key) private view {
        PoolId actual = key.toId();

        if (PoolId.unwrap(actual) != PoolId.unwrap(receipt.poolId)) {
            revert PoolKeyMismatch(receipt.poolId, actual);
        }
    }

    function _finalize(bytes32 id, BondReceipt storage receipt, uint16 persistedBps, ReceiptStatus finalStatus)
        private
    {
        (uint256 requiredRefund, uint256 lpDonation) =
            ImpactBondMath.settlementAmounts(receipt.requiredBond, persistedBps);

        uint256 excessBond = receipt.declaredBond - receipt.requiredBond;

        uint256 traderRefund = excessBond + requiredRefund;

        receipt.status = finalStatus;

        if (traderRefund != 0) {
            IERC20(receipt.bondToken).safeTransfer(receipt.trader, traderRefund);
        }

        if (lpDonation != 0) {
            _queueDonation(receipt.poolId, receipt.bondToken, lpDonation);
        }

        emit BondReceiptFinalized(id, finalStatus, persistedBps, traderRefund, lpDonation);
    }
}
