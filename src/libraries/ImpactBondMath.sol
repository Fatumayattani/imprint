// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title Impact Bond Math
/// @notice Pure calculations for Imprint's impact thresholds, bonds, and refunds.
library ImpactBondMath {
    using SafeCast for uint256;
    uint16 internal constant BPS = 10_000;

    error InvalidBondCurve();

    struct BondCurve {
        uint24 thresholdTicks;
        uint16 baseBondBps;
        uint16 slopeBpsPerTick;
        uint16 maxBondBps;
    }

    /// @notice Returns the absolute distance between two Uniswap ticks.
    function tickDistance(int24 tickA, int24 tickB) internal pure returns (uint24) {
        int256 difference = int256(tickA) - int256(tickB);
        uint256 distance = uint256(difference < 0 ? -difference : difference);

        return distance.toUint24();
    }

    /// @notice Returns the bond rate for a swap's measured price impact.
    /// @dev Swaps at or below the threshold require no bond.
    function bondRateBps(uint24 impactTicks, BondCurve memory curve) internal pure returns (uint16) {
        if (curve.maxBondBps > BPS || curve.baseBondBps > curve.maxBondBps) {
            revert InvalidBondCurve();
        }

        if (impactTicks <= curve.thresholdTicks) return 0;

        uint256 excessTicks = impactTicks - curve.thresholdTicks;
        uint256 uncappedRate = uint256(curve.baseBondBps) + excessTicks * uint256(curve.slopeBpsPerTick);

        if (uncappedRate >= curve.maxBondBps) {
            return curve.maxBondBps;
        }

        return uncappedRate.toUint16();
    }

    /// @notice Calculates the bond amount from a token-denominated notional.
    function bondAmount(uint256 notional, uint24 impactTicks, BondCurve memory curve) internal pure returns (uint256) {
        uint256 rate = bondRateBps(impactTicks, curve);
        return FullMath.mulDiv(notional, rate, BPS);
    }

    /// @notice Measures how much of the initial price displacement persists.
    /// @dev Returns 0 for full reversal and 10,000 for full persistence.
    function persistenceBps(int24 referenceTick, int24 impactTick, int24 settlementTick)
        internal
        pure
        returns (uint16)
    {
        int256 initialDisplacement = int256(impactTick) - int256(referenceTick);

        if (initialDisplacement == 0) return 0;

        int256 remainingDisplacement = int256(settlementTick) - int256(referenceTick);

        // The price returned to or crossed its reference point.
        if (remainingDisplacement == 0 || (remainingDisplacement > 0) != (initialDisplacement > 0)) {
            return 0;
        }

        uint256 initialMagnitude = uint256(initialDisplacement < 0 ? -initialDisplacement : initialDisplacement);

        uint256 remainingMagnitude = uint256(remainingDisplacement < 0 ? -remainingDisplacement : remainingDisplacement);

        // Movement persisted fully or continued in the same direction.
        if (remainingMagnitude >= initialMagnitude) {
            return BPS;
        }

        return uint16(FullMath.mulDiv(remainingMagnitude, BPS, initialMagnitude));
    }

    /// @notice Splits a bond into its refundable and forfeited portions.
    function settlementAmounts(uint256 bond, uint16 persistedBps)
        internal
        pure
        returns (uint256 refund, uint256 forfeiture)
    {
        if (persistedBps > BPS) revert InvalidBondCurve();

        refund = FullMath.mulDiv(bond, persistedBps, BPS);
        forfeiture = bond - refund;
    }
}
