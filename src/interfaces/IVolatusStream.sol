// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVolatusStream
/// @notice Streaming variance coverage, paid per second, on Arc.
interface IVolatusStream {
    event EpochOpened(uint256 indexed epochId, uint64 coverageEnd, uint64 reportDeadline);
    event CapacityPosted(address indexed underwriter, uint256 amount, uint256 shares);
    event CapacityWithdrawn(address indexed underwriter, uint256 shares, uint256 amount);
    event Subscribed(uint256 indexed epochId, address indexed subscriber, uint256 ratePerSecond, uint256 coverage);
    event Funded(uint256 indexed epochId, address indexed subscriber, uint256 amount);
    event Adjusted(uint256 indexed epochId, address indexed subscriber, uint256 ratePerSecond, uint256 coverage);
    event Synced(uint256 indexed epochId, address indexed subscriber, uint64 coveredSeconds, uint256 premiumPaid);
    event PayoffReported(uint256 indexed epochId, uint256 payoffWad);
    event Claimed(uint256 indexed epochId, address indexed subscriber, uint256 payout);
    event PremiumRefunded(uint256 indexed epochId, address indexed subscriber, uint256 amount);

    /// @notice Post USDC that backs coverage, in exchange for a share of premium.
    function postCapacity(uint256 amount) external returns (uint256 shares);

    /// @notice Start streaming premium for coverage on an epoch.
    function subscribe(uint256 epochId, uint256 ratePerSecond, uint256 coverageNotional) external;

    /// @notice Add USDC to a subscription's premium balance. Coverage lapses when it runs dry.
    function fund(uint256 epochId, uint256 amount) external;

    /// @notice Re-price a live subscription. Bills everything already elapsed at the old rate
    ///         first, so re-rating can never retroactively re-price coverage already accrued.
    function adjust(uint256 epochId, uint256 newRatePerSecond, uint256 newCoverageNotional) external;

    /// @notice Bring a subscription's accrual up to date. Permissionless.
    function sync(uint256 epochId, address subscriber) external;

    /// @notice Publish the epoch's settled payoff, as measured on Unichain.
    function reportPayoff(uint256 epochId, uint256 payoffWad) external;

    /// @notice Collect coverage owed, in proportion to how long premium was actually streamed.
    function claim(uint256 epochId) external returns (uint256 payout);
}
