// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VarianceMath
/// @notice Converts a pool's tick path into realized variance and annualized volatility.
///
/// @dev The whole library rests on one identity: a Uniswap tick *is* a log price.
///
///          tick = log_1.0001(price)   =>   ln(price) = tick * ln(1.0001)
///
///      So the log return between two observations is `dTick * ln(1.0001)`, and realized
///      variance — the sum of squared log returns — is
///
///          V = sum(dTick_i^2) * ln(1.0001)^2
///
///      The sum is a pure integer accumulator maintained by the hook. No logarithm is ever
///      evaluated on-chain, no oracle is read, and nothing here touches the swap path: every
///      function below is `pure` and runs at read time.
library VarianceMath {
    /// @notice 1e18 fixed-point scalar. All variance and volatility values are WAD-scaled.
    uint256 internal constant WAD = 1e18;

    /// @notice `ln(1.0001)^2` scaled by 1e27.
    /// @dev ln(1.0001) = 0.00009999500033330833...
    ///      ln(1.0001)^2 = 9.99900009165833409e-9
    ///      Held at 1e27 rather than 1e18 to keep nine extra significant digits through the
    ///      multiply; callers divide by `RAY_TO_WAD` to land back in WAD.
    uint256 internal constant TICK_SQ_TO_VARIANCE_RAY = 9_999_000_091_658_334_094;

    /// @dev 1e27 -> 1e18.
    uint256 internal constant RAY_TO_WAD = 1e9;

    /// @notice Seconds in a 365-day year, the annualization convention used throughout.
    /// @dev A convention, not a law — see the Limitations section of the README.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Largest accumulator `realizedVariance` is guaranteed to convert without
    ///         overflowing. Conservative: the true boundary is a shade higher.
    /// @dev The binding constraint is the *result* fitting in a uint256, not the multiply —
    ///      `Math.mulDiv` carries a 512-bit intermediate, so `accumulator * RAY` never itself
    ///      overflows. That puts the bound at ~1.158e67, a factor of RAY_TO_WAD above the
    ///      naive `uint256.max / RAY`.
    ///
    ///      Unreachable in practice: at the hook's 1000-tick clamp each observation adds at
    ///      most 1e6, so filling it takes ~1.158e61 observations — on the order of 1e53 years
    ///      of one-second blocks. Pinned by `test_maxAccumulator_isARealBound`.
    uint256 internal constant MAX_ACCUMULATOR = (type(uint256).max / TICK_SQ_TO_VARIANCE_RAY) * RAY_TO_WAD;

    /// @notice Elapsed epoch time was zero, so there is nothing to annualize over.
    error ZeroElapsed();

    /// @notice Squares a tick delta into the quantity the accumulator sums.
    /// @dev The only arithmetic on the hot path. `dTick` is bounded by the caller's clamp, so
    ///      the square always fits — but the multiply is deliberately left *checked*. This is a
    ///      library, and an unchecked square silently wraps a large input into a small, wrong,
    ///      perfectly plausible number. A revert is the correct failure for an index that
    ///      settles money. The clamp means the check never fires in production, so it costs
    ///      nothing that matters.
    function squareDelta(int256 dTick) internal pure returns (uint256) {
        // x*x is non-negative for every x, and checked math reverts rather than wrapping to a
        // negative, so the result is always in [0, int256.max]. Pinned by
        // `test_squareDelta_revertsRatherThanWrapping`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(dTick * dTick);
    }

    /// @notice Bounds a single observation's contribution to the accumulator.
    /// @dev A one-block dislocation — a large legitimate trade, a flash-loan spike — must not
    ///      be able to dominate an epoch. Clamping the delta, not the resulting square, keeps
    ///      the bound linear in price and therefore easy to reason about.
    function clampTickDelta(int256 dTick, int256 maxDelta) internal pure returns (int256) {
        if (dTick > maxDelta) return maxDelta;
        if (dTick < -maxDelta) return -maxDelta;
        return dTick;
    }

    /// @notice Realized variance implied by an accumulator of squared tick deltas.
    /// @param accumulator sum of `dTick^2` over the epoch
    /// @return WAD-scaled variance over the epoch's own horizon (not annualized)
    function realizedVariance(uint256 accumulator) internal pure returns (uint256) {
        return Math.mulDiv(accumulator, TICK_SQ_TO_VARIANCE_RAY, RAY_TO_WAD);
    }

    /// @notice Scales an epoch-horizon variance up to a yearly horizon.
    /// @param varianceWad epoch variance, WAD
    /// @param elapsedSeconds wall-clock length of the measured window
    function annualize(uint256 varianceWad, uint256 elapsedSeconds) internal pure returns (uint256) {
        if (elapsedSeconds == 0) revert ZeroElapsed();
        return Math.mulDiv(varianceWad, SECONDS_PER_YEAR, elapsedSeconds);
    }

    /// @notice Annualized volatility: the square root of annualized variance.
    /// @dev `sqrt(v * WAD)` rather than `sqrt(v)` because taking the root of a WAD-scaled
    ///      number halves its scale; pre-multiplying restores it.
    /// @return WAD-scaled volatility, where 1e18 == 100% annualized
    function toVolatility(uint256 annualizedVarianceWad) internal pure returns (uint256) {
        return Math.sqrt(annualizedVarianceWad * WAD);
    }

    /// @notice Accumulator straight through to annualized volatility, in one call.
    function volatilityFromAccumulator(uint256 accumulator, uint256 elapsedSeconds) internal pure returns (uint256) {
        return toVolatility(annualize(realizedVariance(accumulator), elapsedSeconds));
    }
}
