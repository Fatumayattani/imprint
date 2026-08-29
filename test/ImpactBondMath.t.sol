// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ImpactBondMath } from "../src/libraries/ImpactBondMath.sol";

contract ImpactBondMathTest is Test {
    function curve() internal pure returns (ImpactBondMath.BondCurve memory) {
        return
            ImpactBondMath.BondCurve({ thresholdTicks: 50, baseBondBps: 100, slopeBpsPerTick: 10, maxBondBps: 2_000 });
    }

    function exposedBondRate(uint24 impactTicks, ImpactBondMath.BondCurve memory config)
        external
        pure
        returns (uint16)
    {
        return ImpactBondMath.bondRateBps(impactTicks, config);
    }

    function test_tickDistanceIsDirectionIndependent() public pure {
        assertEq(ImpactBondMath.tickDistance(100, 40), 60);
        assertEq(ImpactBondMath.tickDistance(40, 100), 60);
        assertEq(ImpactBondMath.tickDistance(-100, -40), 60);
        assertEq(ImpactBondMath.tickDistance(-40, 20), 60);
    }

    function test_tickDistanceSupportsFullInt24Range() public pure {
        assertEq(ImpactBondMath.tickDistance(type(int24).min, type(int24).max), type(uint24).max);
    }

    function test_noBondAtOrBelowThreshold() public pure {
        ImpactBondMath.BondCurve memory config = curve();

        assertEq(ImpactBondMath.bondRateBps(0, config), 0);
        assertEq(ImpactBondMath.bondRateBps(49, config), 0);
        assertEq(ImpactBondMath.bondRateBps(50, config), 0);
    }

    function test_bondRateGrowsAboveThreshold() public pure {
        ImpactBondMath.BondCurve memory config = curve();

        assertEq(ImpactBondMath.bondRateBps(51, config), 110);
        assertEq(ImpactBondMath.bondRateBps(100, config), 600);
    }

    function test_bondRateIsCapped() public pure {
        ImpactBondMath.BondCurve memory config = curve();

        assertEq(ImpactBondMath.bondRateBps(1_000, config), 2_000);
    }

    function test_invalidBondCurveReverts() public {
        ImpactBondMath.BondCurve memory config = curve();
        config.maxBondBps = 10_001;

        vm.expectRevert(ImpactBondMath.InvalidBondCurve.selector);
        this.exposedBondRate(100, config);

        config.maxBondBps = 50;
        config.baseBondBps = 100;

        vm.expectRevert(ImpactBondMath.InvalidBondCurve.selector);
        this.exposedBondRate(100, config);
    }

    function test_bondAmountUsesTokenNotional() public pure {
        ImpactBondMath.BondCurve memory config = curve();

        // 100 ticks produces a 6% bond.
        assertEq(ImpactBondMath.bondAmount(1_000 ether, 100, config), 60 ether);
    }

    function test_upwardPersistence() public pure {
        assertEq(ImpactBondMath.persistenceBps(0, 100, 0), 0);
        assertEq(ImpactBondMath.persistenceBps(0, 100, 50), 5_000);
        assertEq(ImpactBondMath.persistenceBps(0, 100, 100), 10_000);
        assertEq(ImpactBondMath.persistenceBps(0, 100, 150), 10_000);
        assertEq(ImpactBondMath.persistenceBps(0, 100, -1), 0);
    }

    function test_downwardPersistence() public pure {
        assertEq(ImpactBondMath.persistenceBps(0, -100, 0), 0);
        assertEq(ImpactBondMath.persistenceBps(0, -100, -25), 2_500);
        assertEq(ImpactBondMath.persistenceBps(0, -100, -100), 10_000);
        assertEq(ImpactBondMath.persistenceBps(0, -100, -150), 10_000);
        assertEq(ImpactBondMath.persistenceBps(0, -100, 1), 0);
    }

    function test_zeroInitialDisplacementHasNoPersistence() public pure {
        assertEq(ImpactBondMath.persistenceBps(10, 10, 20), 0);
    }

    function test_settlementSplitsBondWithoutLosingDust() public pure {
        (uint256 refund, uint256 forfeiture) = ImpactBondMath.settlementAmounts(101, 3_333);

        assertEq(refund, 33);
        assertEq(forfeiture, 68);
        assertEq(refund + forfeiture, 101);
    }

    function testFuzz_tickDistanceMatchesSignedDifference(int24 tickA, int24 tickB) public pure {
        int256 difference = int256(tickA) - int256(tickB);
        uint256 expected = uint256(difference < 0 ? -difference : difference);

        assertEq(ImpactBondMath.tickDistance(tickA, tickB), expected);
    }

    function testFuzz_bondRateNeverExceedsCap(uint24 impactTicks) public pure {
        ImpactBondMath.BondCurve memory config = curve();
        uint16 rate = ImpactBondMath.bondRateBps(impactTicks, config);

        assertLe(rate, config.maxBondBps);

        if (impactTicks <= config.thresholdTicks) {
            assertEq(rate, 0);
        }
    }

    function testFuzz_persistenceIsBounded(int24 referenceTick, int24 impactTick, int24 settlementTick) public pure {
        assertLe(ImpactBondMath.persistenceBps(referenceTick, impactTick, settlementTick), 10_000);
    }

    function testFuzz_settlementConservesBond(uint256 bond, uint16 persistence) public pure {
        persistence = uint16(bound(persistence, 0, 10_000));

        (uint256 refund, uint256 forfeiture) = ImpactBondMath.settlementAmounts(bond, persistence);

        assertEq(refund + forfeiture, bond);
    }
}
