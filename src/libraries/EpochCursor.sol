// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VarianceMath} from "./VarianceMath.sol";

/// @title EpochCursor
/// @notice One-observation-per-block sampling of a pool's tick path.
///
/// @dev This is the hook's entire hot path, kept in a library so it can be fuzzed without a
///      PoolManager standing behind it.
///
///      Two properties are deliberate:
///
///      1. **At most one observation per block.** Intra-block round trips contribute exactly
///         nothing, which removes the cheapest way to manufacture variance rather than merely
///         making it expensive. It also means every swap after the first in a block costs a
///         single cold-ish SLOAD and nothing else.
///
///      2. **The accumulator is append-only and never reset.** An epoch's variance is the
///         difference between two snapshots of it, so there is no per-epoch bookkeeping on the
///         swap path, no state for a settlement transaction to race, and no stored mark to
///         poison.
library EpochCursor {
    /// @notice Per-pool sampling state. Two storage slots: the accumulator, then the cursor.
    /// @dev The cursor slot holds 24 + 48 + 32 + 48 = 152 of its 256 bits, so `pendingSnapshot`
    ///      rides along in space that was already being paid for. Reading it on the swap path
    ///      costs nothing beyond the SLOAD the sampling gate performs anyway, and clearing it
    ///      at an epoch boundary lands in a slot the same transaction is already writing.
    struct VarianceState {
        uint256 accumulator; // sum of clamped (dTick)^2 over the pool's whole life
        int24 lastTick; // tick at the last sampled block
        uint48 lastBlock; // block of the last sample
        uint32 observations; // samples taken, ever; see the wraparound note on `observe`
        uint48 pendingSnapshot; // block at/after which to snapshot the accumulator; 0 = none
    }

    /// @notice Whether this block has already been counted for this pool.
    /// @dev One SLOAD: `observations` and `lastBlock` share a slot. Callers use this to skip
    ///      reading the pool's tick at all on a swap that will not be sampled, which is what
    ///      makes every swap after the first in a block genuinely cheap rather than merely
    ///      cheaper.
    function isSampled(VarianceState storage self) internal view returns (bool) {
        // uint48 holds 2.8e14 blocks — 8.9 million years at one-second blocks, against a
        // Unichain Sepolia head of ~6.2e7. The truncation is unreachable.
        // forge-lint: disable-next-line(unsafe-typecast)
        return self.observations != 0 && self.lastBlock == uint48(block.number);
    }

    /// @notice Records a sample if this block has not been sampled yet.
    ///
    /// @dev `observations` is a uint32 and increments unchecked, so it wraps after 4.29e9
    ///      samples — 136 years of one-second blocks. On the wrap the counter reads zero and
    ///      the next observation re-seeds instead of accumulating, costing the index a single
    ///      dropped sample once per 136 years. Accepted deliberately: widening the field would
    ///      push the cursor out of its single storage slot and add an SSTORE to every swap, and
    ///      the accumulator itself — the value that settles money — is untouched by it.
    /// @param maxTickDelta per-observation clamp; bounds any single block's contribution
    /// @return sampled true if state was written, false if this block was already counted
    function observe(VarianceState storage self, int24 tick, int256 maxTickDelta) internal returns (bool sampled) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 currentBlock = uint48(block.number);
        uint32 observations = self.observations;

        // The first sample of a pool's life has no predecessor to difference against, so it
        // seeds the cursor and contributes nothing.
        if (observations == 0) {
            self.lastTick = tick;
            self.lastBlock = currentBlock;
            self.observations = 1;
            return true;
        }

        if (self.lastBlock == currentBlock) return false;

        int256 delta = VarianceMath.clampTickDelta(int256(tick) - int256(self.lastTick), maxTickDelta);

        self.accumulator += VarianceMath.squareDelta(delta);
        self.lastTick = tick;
        self.lastBlock = currentBlock;
        unchecked {
            self.observations = observations + 1;
        }
        return true;
    }
}
