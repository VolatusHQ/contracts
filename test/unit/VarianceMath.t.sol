// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {VarianceMath} from "../../src/libraries/VarianceMath.sol";

contract VarianceMathTest is Test {
    uint256 constant WAD = 1e18;

    /// @dev Reference values computed at 50 decimal digits outside Solidity. The library is
    ///      only worth anything if it agrees with real arithmetic, so these are pinned rather
    ///      than recomputed from the same constants the library uses.
    function test_constant_matchesLnSquared() public pure {
        // ln(1.0001)^2 = 9.99900009165833409437e-9, scaled by 1e27.
        assertEq(VarianceMath.TICK_SQ_TO_VARIANCE_RAY, 9_999_000_091_658_334_094);
    }

    function test_squareDelta() public pure {
        assertEq(VarianceMath.squareDelta(0), 0);
        assertEq(VarianceMath.squareDelta(7), 49);
        assertEq(VarianceMath.squareDelta(-7), 49);
        assertEq(VarianceMath.squareDelta(887272), uint256(887272) * 887272);
    }

    function test_clampTickDelta() public pure {
        assertEq(VarianceMath.clampTickDelta(50, 100), 50, "inside range is identity");
        assertEq(VarianceMath.clampTickDelta(-50, 100), -50, "inside range is identity");
        assertEq(VarianceMath.clampTickDelta(500, 100), 100, "clamped up");
        assertEq(VarianceMath.clampTickDelta(-500, 100), -100, "clamped down");
        assertEq(VarianceMath.clampTickDelta(100, 100), 100, "boundary is inclusive");
    }

    function test_realizedVariance_zero() public pure {
        assertEq(VarianceMath.realizedVariance(0), 0);
    }

    /// @dev acc = 3600 (one tick of movement per second for an hour).
    function test_realizedVariance_knownValue() public pure {
        assertEq(VarianceMath.realizedVariance(3600), 35_996_400_329_970);
    }

    /// @notice The calibration anchor: a pool that moves exactly one tick every second is a
    ///         ~56.15% annualized-vol pool, whether you measure it for an hour or a day.
    function test_volatility_oneTickPerSecond() public pure {
        // Exact real-number answer, to 18 decimals: 0.561541153336545071.
        uint256 expected = 561_541_153_336_545_071;

        uint256 volHour = VarianceMath.volatilityFromAccumulator(3600, 1 hours);
        uint256 volDay = VarianceMath.volatilityFromAccumulator(86_400, 1 days);

        // Three integer divisions floor along the way (variance, annualization, square root),
        // so the result is always at or just below truth — never above it.
        assertLe(volHour, expected, "truncation is one-directional");
        assertApproxEqAbs(volHour, expected, 1000, "56.154115% annualized");
        assertEq(volHour, volDay, "the estimate does not depend on window length");
    }

    /// @notice Ten times the tick movement is ten times the volatility, exactly.
    function test_volatility_scalesLinearlyInTickSize() public pure {
        uint256 vol1 = VarianceMath.volatilityFromAccumulator(3600, 1 hours);
        uint256 vol10 = VarianceMath.volatilityFromAccumulator(360_000, 1 hours);

        assertApproxEqAbs(vol10, vol1 * 10, 10, "variance is quadratic, vol is linear");
    }

    /// @notice `MAX_ACCUMULATOR` documents an overflow bound, so it has to actually be one.
    ///         The true boundary was found by binary search over `realizedVariance`; the
    ///         constant is deliberately the conservative side of it.
    function test_maxAccumulator_isARealBound() public {
        VarianceMathHarness harness = new VarianceMathHarness();

        // Largest input that does not overflow, located by bisection.
        uint256 trueBound = 11_580_366_854_273_333_469_697_167_141_525_426_241_621_510_692_603_397_207_702_977_108_199;

        assertLe(VarianceMath.MAX_ACCUMULATOR, trueBound, "the documented bound must be safe");
        assertGt(
            VarianceMath.MAX_ACCUMULATOR, trueBound - VarianceMath.RAY_TO_WAD, "and tight enough to be worth stating"
        );

        // It converts.
        harness.realizedVariance(VarianceMath.MAX_ACCUMULATOR);
        harness.realizedVariance(trueBound);

        // And one past the true boundary does not.
        vm.expectRevert();
        harness.realizedVariance(trueBound + 1);
    }

    /// @notice A wrapped square is a small, wrong, entirely plausible variance. This asserts
    ///         the library reverts on overflow rather than producing one.
    function test_squareDelta_revertsRatherThanWrapping() public {
        VarianceMathHarness harness = new VarianceMathHarness();

        // Fits: 1.7e38 squared is 2.9e76, inside uint256.
        assertEq(harness.squareDelta(type(int128).max), uint256(int256(type(int128).max)) ** 2);

        vm.expectRevert(stdError.arithmeticError);
        harness.squareDelta(type(int256).max / 2);

        vm.expectRevert(stdError.arithmeticError);
        harness.squareDelta(type(int256).min);
    }

    function test_annualize_revertsOnZeroElapsed() public {
        VarianceMathHarness harness = new VarianceMathHarness();
        vm.expectRevert(VarianceMath.ZeroElapsed.selector);
        harness.annualize(1e18, 0);
    }

    function testFuzz_realizedVariance_monotonic(uint128 a, uint128 b) public pure {
        vm.assume(a < b);
        assertLe(VarianceMath.realizedVariance(a), VarianceMath.realizedVariance(b));
    }

    function testFuzz_clampTickDelta_bounded(int256 delta, int256 maxDelta) public pure {
        maxDelta = bound(maxDelta, 1, type(int24).max);
        delta = bound(delta, type(int128).min, type(int128).max);

        int256 clamped = VarianceMath.clampTickDelta(delta, maxDelta);

        assertLe(clamped, maxDelta);
        assertGe(clamped, -maxDelta);
        // Clamping never flips the direction of a move, and never invents one.
        if (delta > 0) assertGt(clamped, 0);
        if (delta < 0) assertLt(clamped, 0);
        if (delta == 0) assertEq(clamped, 0);
    }

    /// @notice Volatility must be invariant to the window it was measured over, given the same
    ///         per-second rate of accumulation. This is what lets a short Unichain epoch stand
    ///         in for a long one.
    function testFuzz_volatility_windowInvariant(uint64 perSecond, uint32 seconds_) public pure {
        perSecond = uint64(bound(perSecond, 1, 1e6));
        seconds_ = uint32(bound(seconds_, 60, 30 days));

        uint256 short_ = VarianceMath.volatilityFromAccumulator(uint256(perSecond) * 60, 60);
        uint256 long_ = VarianceMath.volatilityFromAccumulator(uint256(perSecond) * seconds_, seconds_);

        // Integer square roots round down, so allow a wei of drift.
        assertApproxEqRel(long_, short_, 1e6, "same rate, same vol");
    }
}

/// @dev `expectRevert` needs a real external call, which an internal library function is not.
contract VarianceMathHarness {
    function annualize(uint256 varianceWad, uint256 elapsedSeconds) external pure returns (uint256) {
        return VarianceMath.annualize(varianceWad, elapsedSeconds);
    }

    function realizedVariance(uint256 accumulator) external pure returns (uint256) {
        return VarianceMath.realizedVariance(accumulator);
    }

    function squareDelta(int256 dTick) external pure returns (uint256) {
        return VarianceMath.squareDelta(dTick);
    }
}
