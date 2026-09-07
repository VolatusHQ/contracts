// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PayoffMath
/// @notice The capped variance payoff, and its inverse.
///
/// @dev An epoch is defined by a variance strike `K` and a cap `C`, with `C > K`. Realized
///      variance `V` is normalized into a payoff `p` in [0, 1]:
///
///          p = clamp(V - K, 0, C - K) / (C - K)
///
///      VAR-LONG redeems for `p` USDC and VAR-SHORT for `1 - p` USDC, so a minted pair always
///      redeems for exactly one USDC. That is the entire solvency argument: the system is
///      fully collateralized by construction, with no insurance fund, no liquidation engine
///      and no path to bad debt.
///
///      Run the same relation backwards on the market price of VAR-LONG and you get implied
///      variance — which is what makes the vol pool a volatility oracle rather than just a
///      prediction market.
library PayoffMath {
    /// @notice 1e18 fixed-point scalar. `p` is WAD-scaled, so 1e18 == full payoff.
    uint256 internal constant WAD = 1e18;

    /// @notice The cap must sit strictly above the strike or the payoff is undefined.
    error InvalidRange(uint256 strike, uint256 cap);

    /// @notice A payoff was supplied outside [0, WAD].
    error PayoffOutOfRange(uint256 payoffWad);

    /// @notice Normalizes realized variance into a payoff in [0, WAD].
    /// @param varianceWad realized variance for the epoch, WAD
    /// @param strikeWad   variance strike `K`, WAD — below this VAR-LONG pays nothing
    /// @param capWad      variance cap `C`, WAD — at or above this VAR-LONG pays in full
    function payoff(uint256 varianceWad, uint256 strikeWad, uint256 capWad) internal pure returns (uint256) {
        if (capWad <= strikeWad) revert InvalidRange(strikeWad, capWad);
        if (varianceWad <= strikeWad) return 0;
        if (varianceWad >= capWad) return WAD;
        // Strictly inside the range, so the division cannot round up to WAD.
        return Math.mulDiv(varianceWad - strikeWad, WAD, capWad - strikeWad);
    }

    /// @notice Recovers the variance a given payoff corresponds to.
    /// @dev The read direction of `payoff`. Applied to the vol pool's price of VAR-LONG it
    ///      yields the market's implied variance for the epoch.
    function impliedVariance(uint256 payoffWad, uint256 strikeWad, uint256 capWad) internal pure returns (uint256) {
        if (capWad <= strikeWad) revert InvalidRange(strikeWad, capWad);
        if (payoffWad > WAD) revert PayoffOutOfRange(payoffWad);
        return strikeWad + Math.mulDiv(payoffWad, capWad - strikeWad, WAD);
    }

    /// @notice Collateral owed to `amount` of a settled leg.
    /// @dev Both legs round *down* independently. Rounding the short leg as the complement of
    ///      the rounded long leg would look tidier, but it lets a set of partial redemptions
    ///      sum to more than the collateral held. Flooring each leg means the vault can only
    ///      ever retain dust, never owe it — which is the invariant
    ///      `test/fuzz/SolvencyInvariant.t.sol` asserts.
    /// @param isLong true for VAR-LONG (pays `p`), false for VAR-SHORT (pays `1 - p`)
    function redemption(uint256 amount, uint256 payoffWad, bool isLong) internal pure returns (uint256) {
        if (payoffWad > WAD) revert PayoffOutOfRange(payoffWad);
        return Math.mulDiv(amount, isLong ? payoffWad : WAD - payoffWad, WAD);
    }
}
