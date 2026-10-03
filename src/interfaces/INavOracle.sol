// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title INavOracle — weekly NAV reference price
/// @dev `navPerShare` is stablecoin base units per 1e18 share units.
interface INavOracle {
    /// @return epoch 0 means no NAV has been posted yet.
    function latest() external view returns (uint64 epoch, uint128 navPerShare, uint64 asOf, uint64 postedAt);

    /// @notice Seconds since the latest NAV's `asOf`. Reverts if no NAV exists.
    function navAge() external view returns (uint64);
}
