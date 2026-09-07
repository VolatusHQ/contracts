// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EpochCursor} from "../../src/libraries/EpochCursor.sol";

/// @dev The library writes to storage, so the tests need a real contract to hold it.
contract CursorHost {
    using EpochCursor for EpochCursor.VarianceState;

    EpochCursor.VarianceState internal _state;

    int256 public constant MAX_TICK_DELTA = 1000;

    function observe(int24 tick) external returns (bool) {
        return _state.observe(tick, MAX_TICK_DELTA);
    }

    function state() external view returns (EpochCursor.VarianceState memory) {
        return _state;
    }

    function accumulator() external view returns (uint256) {
        return _state.accumulator;
    }
}

contract EpochCursorTest is Test {
    CursorHost host;

    function setUp() public {
        host = new CursorHost();
        vm.roll(1000);
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
    }

    function test_firstObservationSeedsWithoutAccumulating() public {
        assertTrue(host.observe(500), "first sample is recorded");

        EpochCursor.VarianceState memory s = host.state();
        assertEq(s.accumulator, 0, "nothing to difference against yet");
        assertEq(s.lastTick, int24(500));
        assertEq(s.observations, 1);
        assertEq(s.lastBlock, uint48(block.number));
    }

    function test_accumulatesSquaredDelta() public {
        host.observe(500);
        _nextBlock();
        host.observe(600);

        assertEq(host.accumulator(), 100 * 100);

        _nextBlock();
        host.observe(570); // a 30-tick move back
        assertEq(host.accumulator(), 100 * 100 + 30 * 30, "direction does not matter");
    }

    /// @notice Defense #1. A wash trader round-tripping inside one block moves the tick and
    ///         moves it back, and contributes exactly nothing for their trouble.
    function test_intraBlockRoundTripsContributeNothing() public {
        host.observe(500);
        _nextBlock();

        assertTrue(host.observe(600), "first swap of the block counts");
        uint256 after1 = host.accumulator();

        assertFalse(host.observe(900), "second swap in the same block does not");
        assertFalse(host.observe(500), "nor the trip back");
        assertFalse(host.observe(20_000), "nor an enormous one");

        assertEq(host.accumulator(), after1, "the accumulator did not move");
        assertEq(host.state().observations, 2, "and no sample was counted");
        assertEq(host.state().lastTick, int24(600), "the block's first tick is what stands");
    }

    /// @notice Defense #3. One block cannot dominate an epoch however violent it is.
    function test_perObservationClampBoundsContribution() public {
        host.observe(0);
        _nextBlock();
        host.observe(type(int24).max); // a full-range dislocation

        assertEq(host.accumulator(), 1000 * 1000, "clamped to MAX_TICK_DELTA squared");
    }

    function test_clampAppliesInBothDirections() public {
        host.observe(0);
        _nextBlock();
        host.observe(type(int24).min);

        assertEq(host.accumulator(), 1000 * 1000);
    }

    /// @notice The accumulator is append-only: an epoch is a difference of two snapshots, so
    ///         there is no per-epoch state on the swap path for settlement to race.
    function test_accumulatorIsMonotonic() public {
        host.observe(0);
        uint256 previous = 0;

        for (uint256 i = 0; i < 32; i++) {
            _nextBlock();
            host.observe(int24(int256(i * 37 % 800)));
            assertGe(host.accumulator(), previous, "never decreases");
            previous = host.accumulator();
        }
    }

    /// @notice A pool that does not move accumulates no variance, no matter how much it trades.
    function test_flatPoolAccumulatesNothing() public {
        host.observe(1234);
        for (uint256 i = 0; i < 20; i++) {
            _nextBlock();
            host.observe(1234);
        }
        assertEq(host.accumulator(), 0);
        assertEq(host.state().observations, 21);
    }

    /// @notice Manufacturing variance costs the attacker a swap fee in every block they use,
    ///         and each block buys them at most one clamped observation. This is the shape of
    ///         the bound `test/fuzz/ManipulationCost.t.sol` will make quantitative.
    function testFuzz_gainPerBlockIsBounded(int24[16] memory ticks, uint8 swapsPerBlock) public {
        uint256 swaps = bound(swapsPerBlock, 1, 20);
        uint256 maxContribution = uint256(host.MAX_TICK_DELTA() ** 2);

        host.observe(0);

        for (uint256 i = 0; i < ticks.length; i++) {
            _nextBlock();
            uint256 before = host.accumulator();

            for (uint256 j = 0; j < swaps; j++) {
                host.observe(ticks[i]);
            }

            assertLe(host.accumulator() - before, maxContribution, "one block, one clamped sample");
        }
    }
}
