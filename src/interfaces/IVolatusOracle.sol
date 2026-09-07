// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IVolatusOracle
/// @notice What other protocols integrate against. One view call.
///
/// @dev A dynamic-fee hook pricing off market-implied volatility instead of a trailing window:
///
///     uint256 iv  = volatusOracle.impliedVol(poolId);
///     uint24  fee = baseFee + uint24(iv * feeSensitivity / 1e18);
interface IVolatusOracle {
    /// @notice Market-implied volatility for a pool, annualized, 1e18 fixed point.
    /// @dev 1e18 == 100% annualized. Reverts if the pool has no epoch with a registered vol
    ///      pool — a caller that must not revert should use `tryImpliedVol`.
    function impliedVol(PoolId id) external view returns (uint256);

    /// @notice Non-reverting form for integrators who would rather fall back than fail.
    function tryImpliedVol(PoolId id) external view returns (bool ok, uint256 impliedVolWad);

    /// @notice Realized variance accumulated so far in the pool's current epoch, WAD.
    function realizedVariance(PoolId id) external view returns (uint256);

    /// @notice Annualized realized volatility so far in the current epoch, WAD.
    function realizedVol(PoolId id) external view returns (uint256);

    /// @notice Current epoch parameters for a pool.
    function epoch(PoolId id) external view returns (uint64 endBlock, uint256 strike, uint256 cap);

    /// @notice The market's price of VAR-LONG, WAD in [0, 1] — normalized implied variance.
    function normalizedImpliedVariance(PoolId id) external view returns (uint256);
}
