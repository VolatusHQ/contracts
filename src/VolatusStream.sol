// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVolatusStream} from "./interfaces/IVolatusStream.sol";

/// @title VolatusStream
/// @notice Variance coverage as a subscription, priced per second, settled on Arc.
///
/// @dev Buying an epoch's protection up front is a fossil of transaction costs: you batch risk
///      into lump-sum contracts because paying continuously used to cost more than the payment.
///      Circle Nanopayments removes that floor, so coverage becomes a stream — an LP pays per
///      second at the prevailing rate and coverage accrues tick by tick. Stop paying and coverage
///      lapses at the next tick. No term, no expiry, no lockup on the buyer's side.
///
///      **Premium arrives as ordinary USDC.** Gateway's flow is deposit, signed burn intent,
///      attestation, then `gatewayMint` on the destination chain, so by the time value reaches
///      this contract it is native USDC on Arc. Nothing here needs to understand Gateway; the
///      cheapness of topping up is what makes per-second granularity viable, and that happens
///      entirely off this contract.
///
///      **Coverage is proportional to time actually paid for.** A subscriber who streams for
///      half the epoch is covered for half the notional. Accrual is lazy: `sync` credits elapsed
///      time against the funded balance, and stops at the exact second the balance ran dry, so
///      an unfunded subscription silently stops accruing rather than accruing a debt.
///
///      **The cross-chain seam, stated plainly.** The payoff is measured and settled on
///      Unichain; this contract is on Arc and cannot read it. A `settlementReporter` fixed at
///      construction publishes it once, immutably. That is a real trust surface and it is the
///      only one here. It is bounded by a fail-safe: if no report arrives by `reportDeadline`,
///      subscribers reclaim their unspent premium and underwriters reclaim their capacity. So
///      the README's liveness claim holds literally — if Arc, Gateway, the agents or the
///      reporter are unavailable, coverage lapses and nothing is stuck.
///
///      **On `block.timestamp`.** A per-second subscription is inherently a function of wall
///      clock time, so this contract compares timestamps in several places and a linter will
///      flag every one. The exposure is bounded and uninteresting: a validator nudging the clock
///      by a few seconds moves a subscriber's premium by a few seconds' worth — cents — and
///      moves coverage by the same proportion in the same direction, so the two stay consistent.
///      Nothing here uses time as a source of randomness, and nothing settles on it: the payoff
///      comes from the accumulator on Unichain, which is indexed by block number and cannot be
///      moved by a timestamp at all. Timestamps are used deliberately rather than block numbers
///      because a premium rate quoted per second must not change meaning when block times drift.
///
///      All timestamp casts to `uint64` are safe: uint64 seconds overflows in the year 584
///      billion.
///
///      Scope, deliberately: one underwriter pool, capacity shared pro-rata, one epoch at a
///      time. Matching the vault's "one epoch length, one cap" cut.
contract VolatusStream is IVolatusStream, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;

    struct Epoch {
        uint64 coverageStart;
        uint64 coverageEnd;
        uint64 reportDeadline;
        bool reported;
        uint256 payoffWad;
        uint256 totalCoverageSold; // notional-seconds sold, for pro-rata loss sharing
    }

    struct Subscription {
        uint256 ratePerSecond;
        uint256 coverageNotional;
        uint256 funded; // premium not yet consumed
        uint64 lastSync;
        uint64 coveredSeconds; // seconds actually paid for
        bool claimed;
    }

    IERC20 public immutable usdc;

    /// @notice Publishes the settled payoff measured on Unichain. Fixed at construction.
    address public immutable settlementReporter;

    /// @notice Total USDC posted by underwriters, plus premium earned, minus claims paid.
    uint256 public capacityPool;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => mapping(address => Subscription)) internal _subs;

    error ZeroAddress();
    error NotReporter();
    error EpochExists(uint256 epochId);
    error NoSuchEpoch(uint256 epochId);
    error EpochNotOver(uint256 epochId);
    error AlreadyReported(uint256 epochId);
    error ReportWindowClosed(uint256 epochId);
    error PayoffOutOfRange(uint256 payoffWad);
    error AlreadySubscribed(uint256 epochId);
    error ZeroRate();
    error NoSubscription(uint256 epochId);
    error NotReportedYet(uint256 epochId);
    error AlreadyClaimed(uint256 epochId);
    error NothingPosted();
    error InsufficientCapacity(uint256 requested, uint256 available);

    constructor(IERC20 usdc_, address settlementReporter_) {
        if (address(usdc_) == address(0) || settlementReporter_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        settlementReporter = settlementReporter_;
    }

    modifier onlyReporter() {
        if (msg.sender != settlementReporter) revert NotReporter();
        _;
    }

    // -------------------------------------------------------------------------
    // Epochs
    // -------------------------------------------------------------------------

    /// @notice Mirrors an epoch that already exists in the vault on Unichain.
    /// @param reportDeadline after this, an unreported epoch becomes refundable to everyone.
    function openEpoch(uint256 epochId, uint64 coverageEnd, uint64 reportDeadline) external onlyReporter {
        Epoch storage e = _epochs[epochId];
        if (e.coverageEnd != 0) revert EpochExists(epochId);

        // forge-lint: disable-next-line(unsafe-typecast)
        e.coverageStart = uint64(block.timestamp);
        e.coverageEnd = coverageEnd;
        e.reportDeadline = reportDeadline;

        emit EpochOpened(epochId, coverageEnd, reportDeadline);
    }

    /// @inheritdoc IVolatusStream
    function reportPayoff(uint256 epochId, uint256 payoffWad) external onlyReporter {
        Epoch storage e = _epoch(epochId);
        if (e.reported) revert AlreadyReported(epochId);
        if (block.timestamp < e.coverageEnd) revert EpochNotOver(epochId);
        if (block.timestamp > e.reportDeadline) revert ReportWindowClosed(epochId);
        if (payoffWad > WAD) revert PayoffOutOfRange(payoffWad);

        e.reported = true;
        e.payoffWad = payoffWad;

        emit PayoffReported(epochId, payoffWad);
    }

    // -------------------------------------------------------------------------
    // Underwriters
    // -------------------------------------------------------------------------

    /// @inheritdoc IVolatusStream
    /// @dev Shares are minted against the pool's current value, so premium already earned
    ///      accrues to the underwriters who were exposed when it was earned.
    function postCapacity(uint256 amount) external nonReentrant returns (uint256 mintedShares) {
        if (amount == 0) revert NothingPosted();

        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - before;

        mintedShares = capacityPool == 0 ? received : Math.mulDiv(received, totalShares, capacityPool);

        capacityPool += received;
        totalShares += mintedShares;
        shares[msg.sender] += mintedShares;

        emit CapacityPosted(msg.sender, received, mintedShares);
    }

    /// @notice Withdraw capacity plus earned premium, minus any claims paid.
    function withdrawCapacity(uint256 shareAmount) external nonReentrant returns (uint256 amount) {
        shares[msg.sender] -= shareAmount;
        amount = Math.mulDiv(shareAmount, capacityPool, totalShares);

        totalShares -= shareAmount;
        capacityPool -= amount;

        usdc.safeTransfer(msg.sender, amount);
        emit CapacityWithdrawn(msg.sender, shareAmount, amount);
    }

    // -------------------------------------------------------------------------
    // Subscribers
    // -------------------------------------------------------------------------

    /// @inheritdoc IVolatusStream
    function subscribe(uint256 epochId, uint256 ratePerSecond, uint256 coverageNotional) external {
        Epoch storage e = _epoch(epochId);
        Subscription storage s = _subs[epochId][msg.sender];
        if (s.ratePerSecond != 0) revert AlreadySubscribed(epochId);

        // Coverage must be backed by capacity that actually exists.
        if (coverageNotional > capacityPool) revert InsufficientCapacity(coverageNotional, capacityPool);

        s.ratePerSecond = ratePerSecond;
        s.coverageNotional = coverageNotional;
        // forge-lint: disable-next-line(unsafe-typecast)
        s.lastSync = uint64(Math.max(block.timestamp, e.coverageStart));

        emit Subscribed(epochId, msg.sender, ratePerSecond, coverageNotional);
    }

    /// @inheritdoc IVolatusStream
    function fund(uint256 epochId, uint256 amount) external nonReentrant {
        _epoch(epochId);
        Subscription storage s = _subs[epochId][msg.sender];
        if (s.ratePerSecond == 0) revert NoSubscription(epochId);

        _sync(epochId, msg.sender);

        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        s.funded += usdc.balanceOf(address(this)) - before;

        emit Funded(epochId, msg.sender, amount);
    }

    /// @inheritdoc IVolatusStream
    /// @dev The premium rate re-prices against live implied volatility, so a subscription that
    ///      could never change its rate would have to be re-opened every time the market moved
    ///      — losing the coverage already accrued. This is the seam the hedger agent drives.
    ///
    ///      Ordering is the whole correctness argument: `_sync` runs **first**, so every second
    ///      already elapsed is billed at the rate that was quoted while it elapsed. Re-rating
    ///      can never reach backwards and re-price coverage the subscriber has already been
    ///      credited with, in either direction.
    ///
    ///      A zero rate is rejected rather than treated as a pause. Once created, a
    ///      subscription always has a non-zero rate, which is the invariant `NoSubscription`
    ///      and `_sync`'s early return both read. Stopping is expressed by not topping up:
    ///      the balance drains, coverage lapses at that exact second, and nothing accrues a
    ///      debt — the same fail-safe direction as everywhere else in this contract.
    function adjust(uint256 epochId, uint256 newRatePerSecond, uint256 newCoverageNotional)
        external
    {
        _epoch(epochId);
        Subscription storage s = _subs[epochId][msg.sender];
        if (s.ratePerSecond == 0) revert NoSubscription(epochId);
        if (newRatePerSecond == 0) revert ZeroRate();

        // Bill the old rate for the time it actually applied to, before it changes.
        _sync(epochId, msg.sender);

        // Same invariant subscribe enforces: coverage must be backed by capacity that exists.
        if (newCoverageNotional > capacityPool) {
            revert InsufficientCapacity(newCoverageNotional, capacityPool);
        }

        s.ratePerSecond = newRatePerSecond;
        s.coverageNotional = newCoverageNotional;

        emit Adjusted(epochId, msg.sender, newRatePerSecond, newCoverageNotional);
    }

    /// @inheritdoc IVolatusStream
    function sync(uint256 epochId, address subscriber) external {
        _epoch(epochId);
        _sync(epochId, subscriber);
    }

    /// @dev Credits elapsed time against the funded balance and stops the moment it runs dry.
    ///      An unfunded subscription therefore stops accruing coverage rather than accruing a
    ///      debt — the fail-safe direction.
    function _sync(uint256 epochId, address subscriber) internal {
        Epoch storage e = _epochs[epochId];
        Subscription storage s = _subs[epochId][subscriber];
        if (s.ratePerSecond == 0) return;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 upTo = uint64(Math.min(block.timestamp, e.coverageEnd));
        if (upTo <= s.lastSync) return;

        uint64 elapsed = upTo - s.lastSync;
        uint256 owed = uint256(elapsed) * s.ratePerSecond;

        uint64 paidSeconds;
        uint256 premium;

        if (owed <= s.funded) {
            paidSeconds = elapsed;
            premium = owed;
        } else {
            // Ran dry partway through. Cover only what the balance actually bought.
            // forge-lint: disable-next-line(unsafe-typecast)
            paidSeconds = uint64(s.funded / s.ratePerSecond);
            premium = uint256(paidSeconds) * s.ratePerSecond;
        }

        s.funded -= premium;
        s.coveredSeconds += paidSeconds;
        s.lastSync = upTo;

        // Premium is income to the underwriter pool the moment it is earned.
        capacityPool += premium;
        e.totalCoverageSold += uint256(paidSeconds) * s.coverageNotional;

        emit Synced(epochId, subscriber, s.coveredSeconds, premium);
    }

    /// @inheritdoc IVolatusStream
    /// @dev Payout is the notional scaled by the payoff and by the fraction of the epoch the
    ///      subscriber actually paid for. Capped by the pool, so the contract can never promise
    ///      more than it holds.
    function claim(uint256 epochId) external nonReentrant returns (uint256 payout) {
        Epoch storage e = _epoch(epochId);
        if (!e.reported) revert NotReportedYet(epochId);

        Subscription storage s = _subs[epochId][msg.sender];
        if (s.ratePerSecond == 0) revert NoSubscription(epochId);
        if (s.claimed) revert AlreadyClaimed(epochId);

        _sync(epochId, msg.sender);
        s.claimed = true;

        uint64 epochSeconds = e.coverageEnd - e.coverageStart;
        if (epochSeconds != 0 && e.payoffWad != 0) {
            payout = Math.mulDiv(Math.mulDiv(s.coverageNotional, e.payoffWad, WAD), s.coveredSeconds, epochSeconds);
            if (payout > capacityPool) payout = capacityPool;
        }

        uint256 refund = s.funded;
        s.funded = 0;

        if (payout != 0) {
            capacityPool -= payout;
            usdc.safeTransfer(msg.sender, payout);
            emit Claimed(epochId, msg.sender, payout);
        }
        if (refund != 0) {
            usdc.safeTransfer(msg.sender, refund);
            emit PremiumRefunded(epochId, msg.sender, refund);
        }
    }

    /// @notice Fail-safe. If the reporter never published, subscribers take back every unspent
    ///         unit of premium. Coverage simply never existed; nothing is stuck.
    function reclaimUnreported(uint256 epochId) external nonReentrant returns (uint256 refund) {
        Epoch storage e = _epoch(epochId);
        if (e.reported) revert AlreadyReported(epochId);
        if (block.timestamp <= e.reportDeadline) revert EpochNotOver(epochId);

        Subscription storage s = _subs[epochId][msg.sender];
        if (s.claimed) revert AlreadyClaimed(epochId);
        s.claimed = true;

        refund = s.funded;
        s.funded = 0;

        if (refund != 0) {
            usdc.safeTransfer(msg.sender, refund);
            emit PremiumRefunded(epochId, msg.sender, refund);
        }
    }

    /// @notice Cancel a stream. Coverage stops accruing at this instant and unspent premium is
    ///         returned. The buyer is never locked in — that is the point of a subscription.
    function cancel(uint256 epochId) external nonReentrant returns (uint256 refund) {
        _epoch(epochId);
        Subscription storage s = _subs[epochId][msg.sender];
        if (s.ratePerSecond == 0) revert NoSubscription(epochId);

        _sync(epochId, msg.sender);

        refund = s.funded;
        s.funded = 0;
        s.ratePerSecond = 0;

        if (refund != 0) {
            usdc.safeTransfer(msg.sender, refund);
            emit PremiumRefunded(epochId, msg.sender, refund);
        }
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function epoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function subscription(uint256 epochId, address subscriber) external view returns (Subscription memory) {
        return _subs[epochId][subscriber];
    }

    /// @notice Seconds of coverage the current premium balance still buys.
    function runwaySeconds(uint256 epochId, address subscriber) external view returns (uint256) {
        Subscription storage s = _subs[epochId][subscriber];
        if (s.ratePerSecond == 0) return 0;
        return s.funded / s.ratePerSecond;
    }

    function _epoch(uint256 epochId) internal view returns (Epoch storage e) {
        e = _epochs[epochId];
        if (e.coverageEnd == 0) revert NoSuchEpoch(epochId);
    }
}
