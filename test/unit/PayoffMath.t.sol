// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PayoffMath} from "../../src/libraries/PayoffMath.sol";

contract PayoffMathTest is Test {
    uint256 constant WAD = 1e18;

    // A 0.10 -> 0.40 variance band, i.e. roughly 32% to 63% annualized vol.
    uint256 constant K = 0.1e18;
    uint256 constant C = 0.4e18;

    PayoffHarness harness;

    function setUp() public {
        harness = new PayoffHarness();
    }

    function test_payoff_belowStrikeIsZero() public pure {
        assertEq(PayoffMath.payoff(0, K, C), 0);
        assertEq(PayoffMath.payoff(K - 1, K, C), 0);
        assertEq(PayoffMath.payoff(K, K, C), 0, "at the strike, still nothing");
    }

    function test_payoff_atOrAboveCapIsFull() public pure {
        assertEq(PayoffMath.payoff(C, K, C), WAD);
        assertEq(PayoffMath.payoff(C + 1, K, C), WAD);
        assertEq(PayoffMath.payoff(type(uint128).max, K, C), WAD, "the cap is what bounds an attack");
    }

    function test_payoff_midpoint() public pure {
        assertEq(PayoffMath.payoff(0.25e18, K, C), 0.5e18);
        assertEq(PayoffMath.payoff(0.175e18, K, C), 0.25e18);
    }

    function test_payoff_revertsOnInvertedRange() public {
        vm.expectRevert(abi.encodeWithSelector(PayoffMath.InvalidRange.selector, C, K));
        harness.payoff(0.2e18, C, K);

        vm.expectRevert(abi.encodeWithSelector(PayoffMath.InvalidRange.selector, K, K));
        harness.payoff(0.2e18, K, K);
    }

    function test_impliedVariance_roundTrip() public pure {
        assertEq(PayoffMath.impliedVariance(0, K, C), K);
        assertEq(PayoffMath.impliedVariance(WAD, K, C), C);
        assertEq(PayoffMath.impliedVariance(0.5e18, K, C), 0.25e18);
    }

    function test_impliedVariance_revertsAbovePar() public {
        vm.expectRevert(abi.encodeWithSelector(PayoffMath.PayoffOutOfRange.selector, WAD + 1));
        harness.impliedVariance(WAD + 1, K, C);
    }

    function test_redemption_endpoints() public pure {
        assertEq(PayoffMath.redemption(1_000e6, 0, true), 0, "long is worthless at p = 0");
        assertEq(PayoffMath.redemption(1_000e6, 0, false), 1_000e6, "short takes the whole dollar");
        assertEq(PayoffMath.redemption(1_000e6, WAD, true), 1_000e6);
        assertEq(PayoffMath.redemption(1_000e6, WAD, false), 0);
    }

    // -------------------------------------------------------------------------
    // Properties
    // -------------------------------------------------------------------------

    /// @notice The solvency argument in one assertion: a minted pair never redeems for more
    ///         than the collateral that minted it, at any payoff, for any size.
    function testFuzz_pairNeverRedeemsForMoreThanItMinted(uint128 amount, uint256 payoffWad) public pure {
        payoffWad = bound(payoffWad, 0, WAD);

        uint256 long_ = PayoffMath.redemption(amount, payoffWad, true);
        uint256 short_ = PayoffMath.redemption(amount, payoffWad, false);

        assertLe(long_ + short_, amount, "the vault can retain dust, never owe it");
        // Both legs floor independently, so the pair gives up at most one wei on each side.
        assertLe(uint256(amount) - (long_ + short_), 2, "and the dust really is dust");
    }

    function testFuzz_payoff_isBoundedAndMonotonic(uint256 v1, uint256 v2, uint256 strike, uint256 cap) public pure {
        strike = bound(strike, 0, 100e18);
        cap = bound(cap, strike + 1, 200e18);
        v1 = bound(v1, 0, 300e18);
        v2 = bound(v2, v1, 300e18);

        uint256 p1 = PayoffMath.payoff(v1, strike, cap);
        uint256 p2 = PayoffMath.payoff(v2, strike, cap);

        assertLe(p1, WAD, "payoff never exceeds par");
        assertLe(p1, p2, "more realized variance never pays less");
    }

    /// @notice Reading the market price of VAR-LONG back into a variance must land where the
    ///         forward payoff put it. This is the step that turns a price into an oracle.
    function testFuzz_impliedVariance_invertsPayoff(uint256 varianceWad, uint256 strike, uint256 cap) public pure {
        strike = bound(strike, 0, 10e18);
        cap = bound(cap, strike + 1e12, 50e18);
        varianceWad = bound(varianceWad, strike, cap);

        uint256 p = PayoffMath.payoff(varianceWad, strike, cap);
        uint256 recovered = PayoffMath.impliedVariance(p, strike, cap);

        // One WAD division floors on the way out and another on the way back, so the round
        // trip loses at most the width of the band divided by 1e18.
        assertApproxEqAbs(recovered, varianceWad, (cap - strike) / WAD + 1);
    }
}

/// @dev `expectRevert` needs a real external call frame.
contract PayoffHarness {
    function payoff(uint256 v, uint256 k, uint256 c) external pure returns (uint256) {
        return PayoffMath.payoff(v, k, c);
    }

    function impliedVariance(uint256 p, uint256 k, uint256 c) external pure returns (uint256) {
        return PayoffMath.impliedVariance(p, k, c);
    }
}
