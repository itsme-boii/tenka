// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISettlementDesk — atomic share-for-stablecoin settlement
interface ISettlementDesk {
    /// @notice A seller's signed offer. `payment` is the total stablecoin amount for all
    ///         `shares`, so no per-share rounding exists in the order itself. The price
    ///         is whatever the seller signs.
    /// @dev `buyer == address(0)` allows any whitelisted buyer.
    ///      `navEpoch == 0` means the order is not bound to a NAV epoch.
    ///      `maxNavAge == 0` means the order has no NAV age limit.
    ///      `allowPartial` lets a buyer take part of the order. A nonce identifies one
    ///      order, so a seller must not reuse a nonce for a different order.
    struct Order {
        address seller;
        address buyer;
        uint256 shares;
        uint256 payment;
        uint64 navEpoch;
        uint64 maxNavAge;
        bool allowPartial;
        uint256 nonce;
        uint256 deadline;
    }

    function fill(Order calldata order, bytes calldata signature, uint256 fillShares) external;
    function cancel(uint256[] calldata nonces) external;
    function hashOrder(Order calldata order) external view returns (bytes32);
}
