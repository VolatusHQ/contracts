// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EpochCursor} from "../libraries/EpochCursor.sol";

/// @title IVolatusHook
/// @notice The measurement surface: a pool's own realized-variance accumulator.
interface IVolatusHook {
    /// @notice Emitted once per sampled block. Not emitted for later swaps in the same block.
    event VarianceObserved(PoolId indexed id, int24 tick, uint256 accumulator, uint32 observations);

    /// @notice Emitted the first time a pool is initialized with this hook attached.
    event PoolTracked(PoolId indexed id, int24 tick);

    /// @notice Emitted when a settled epoch's pending boundary is freed for the next epoch.
    event SnapshotReleased(PoolId indexed id, uint48 indexed atBlock);

    /// @notice Emitted when a snapshot is requested for a pool's epoch boundary.
    event SnapshotRequested(PoolId indexed id, uint48 indexed atBlock);

    /// @notice Emitted when the pool's own first swap at or after `atBlock` freezes the
    ///         accumulator for settlement.
    event SnapshotTaken(PoolId indexed id, uint48 indexed atBlock, uint256 accumulator);

    /// @notice Emitted once, when the vault permitted to request snapshots is fixed.
    event VaultSet(address indexed vault);

    /// @notice Full sampling state for a pool.
    function varianceState(PoolId id) external view returns (EpochCursor.VarianceState memory);

    /// @notice The pool's lifetime accumulator of clamped squared tick deltas.
    /// @dev Append-only. A window's variance is the difference between two readings of this.
    function accumulator(PoolId id) external view returns (uint256);

    /// @notice Number of blocks sampled for this pool, ever.
    function observations(PoolId id) external view returns (uint32);

    /// @notice Block of the pool's most recent sample.
    function lastObservedBlock(PoolId id) external view returns (uint48);

    /// @notice The accumulator frozen at a requested epoch boundary.
    /// @return taken whether the boundary has been crossed and recorded
    /// @return accumulatorAtBlock the frozen value; meaningless unless `taken`
    function snapshotAt(PoolId id, uint48 atBlock) external view returns (bool taken, uint256 accumulatorAtBlock);

    /// @notice Asks the hook to freeze the accumulator at `atBlock`. Vault only.
    function requestSnapshot(PoolId id, uint48 atBlock) external;

    /// @notice Frees a pool's pending boundary once its epoch has settled. Vault only.
    function releaseSnapshot(PoolId id) external;

    /// @notice Realized variance accrued between two accumulator snapshots, WAD-scaled.
    function varianceBetween(uint256 startAccumulator, uint256 endAccumulator)
        external
        pure
        returns (uint256 varianceWad);

    /// @notice Annualized volatility implied by a window of accumulation, WAD-scaled.
    function realizedVolatility(uint256 startAccumulator, uint256 endAccumulator, uint256 elapsedSeconds)
        external
        pure
        returns (uint256 volatilityWad);
}
