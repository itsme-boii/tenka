// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title UpgradeTimelock — queued, publicly visible UUPS upgrades with a veto key
/// @notice Every Halden contract inherits this. An upgrade must be queued at least
///         `UPGRADE_DELAY` before it can run, and it must run inside `UPGRADE_WINDOW`.
///         The pending implementation is on-chain, so anyone can inspect it first.
///         A separate `guardian` key can cancel a queued upgrade but can never queue or
///         execute one.
/// @dev Closes the common "upgrade with no timelock" gap. State lives
///      in ERC-7201 namespaced storage, so it never shifts the host's storage slots.
///      The guardian is only a real check if its key is held apart from the owner's,
///      because the owner can replace it. `NavOracle` also uses it as the NAV veto key.
abstract contract UpgradeTimelock is Ownable2StepUpgradeable, UUPSUpgradeable {
    // ──────────── Constants ────────────

    uint256 public constant UPGRADE_DELAY = 48 hours;
    uint256 public constant UPGRADE_WINDOW = 7 days;

    /// @dev keccak256(abi.encode(uint256(keccak256("halden.storage.UpgradeTimelock")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_SLOT = 0xdea8b38ba794b7a048a7b3ae621d9b372160415e4a735581ba19efab120dd500;

    // ──────────── State ────────────

    struct Layout {
        address implementation;
        uint64 eta;
        address guardian;
    }

    // ──────────── Events ────────────

    event UpgradeQueued(address indexed implementation, uint64 eta);
    event UpgradeCancelled(address indexed implementation, address indexed by);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ──────────── Errors ────────────

    error ZeroAddress();
    error NotAContract();
    error OnlyOwnerOrGuardian();
    error UpgradeNotQueued();
    error UpgradeTooEarly();
    error UpgradeWindowExpired();

    // ──────────── Modifiers ────────────

    modifier onlyOwnerOrGuardian() {
        address g = _layout().guardian;
        if (msg.sender != owner() && (g == address(0) || msg.sender != g)) revert OnlyOwnerOrGuardian();
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //                    OWNER: UPGRADE QUEUE
    // ══════════════════════════════════════════════════════════════

    /// @notice Queue `implementation` for upgrade. Replaces any earlier queued upgrade.
    function queueUpgrade(address implementation) external onlyOwner {
        if (implementation == address(0)) revert ZeroAddress();
        if (implementation.code.length == 0) revert NotAContract();
        Layout storage l = _layout();
        l.implementation = implementation;
        l.eta = uint64(block.timestamp + UPGRADE_DELAY);
        emit UpgradeQueued(implementation, l.eta);
    }

    /// @notice Drop the queued upgrade. The guardian may also call this.
    function cancelUpgrade() external onlyOwnerOrGuardian {
        Layout storage l = _layout();
        address implementation = l.implementation;
        if (implementation == address(0)) revert UpgradeNotQueued();
        delete l.implementation;
        delete l.eta;
        emit UpgradeCancelled(implementation, msg.sender);
    }

    /// @notice Set the guardian. Zero means no guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    // ══════════════════════════════════════════════════════════════
    //                    VIEWS
    // ══════════════════════════════════════════════════════════════

    /// @notice The upgrade currently waiting, if any.
    function queuedUpgrade() external view returns (address implementation, uint64 eta) {
        Layout storage l = _layout();
        return (l.implementation, l.eta);
    }

    function guardian() public view returns (address) {
        return _layout().guardian;
    }

    // ──────────── Internal ────────────

    function _setGuardian(address newGuardian) internal {
        emit GuardianUpdated(_layout().guardian, newGuardian);
        _layout().guardian = newGuardian;
    }

    /// @dev Only the exact queued implementation may be installed, after the delay and
    ///      before the window closes. The queue entry is consumed on use.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        Layout storage l = _layout();
        if (l.implementation == address(0) || l.implementation != newImplementation) revert UpgradeNotQueued();
        if (block.timestamp < l.eta) revert UpgradeTooEarly();
        if (block.timestamp > l.eta + UPGRADE_WINDOW) revert UpgradeWindowExpired();
        delete l.implementation;
        delete l.eta;
    }

    function _layout() private pure returns (Layout storage l) {
        bytes32 slot = _STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}
