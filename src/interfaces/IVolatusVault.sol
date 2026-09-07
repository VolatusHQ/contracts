// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IVolatusVault
/// @notice Mint, burn, settle and redeem capped variance pairs against USDC collateral.
interface IVolatusVault {
    event EpochOpened(
        uint256 indexed epochId,
        PoolId indexed poolId,
        uint48 endBlock,
        uint256 strikeWad,
        uint256 capWad,
        address longToken,
        address shortToken
    );
    event PairMinted(uint256 indexed epochId, address indexed to, uint256 amount);
    event PairBurned(uint256 indexed epochId, address indexed from, uint256 amount);
    event EpochSettled(uint256 indexed epochId, uint256 realizedVarianceWad, uint256 payoffWad);
    event Redeemed(uint256 indexed epochId, address indexed holder, bool isLong, uint256 amount, uint256 payout);

    /// @notice Deposit `amount` collateral, receive `amount` of each leg.
    function mintPair(uint256 epochId, uint256 amount) external;

    /// @notice Return one of each leg before settlement, receive collateral back.
    function burnPair(uint256 epochId, uint256 amount) external;

    /// @notice Freeze the payoff from the accumulator. Permissionless after `endBlock`.
    function settle(uint256 epochId) external returns (uint256 payoffWad);

    /// @notice Redeem a settled leg for its share of collateral.
    function redeem(uint256 epochId, bool isLong, uint256 amount) external returns (uint256 payout);
}
