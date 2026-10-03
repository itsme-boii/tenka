// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UpgradeTimelock} from "./UpgradeTimelock.sol";

/// @title ShareToken — fund share token that only whitelisted wallets can hold
/// @notice An 18-decimal ERC20. Every transfer requires both the sender and the receiver
///         to be whitelisted, so the restriction holds whether the transfer comes from
///         the settlement desk, a wallet, or any other contract. A whitelist entry can
///         carry an expiry, after which the wallet counts as removed.
/// @dev A wallet that is removed or expired is frozen: it cannot send or receive until it
///      is whitelisted again. There is deliberately no `forceTransfer`, so the owner can
///      never move a holder's shares to someone else. The owner can mint, and can burn
///      from any wallet including a frozen one (for example under a court order). Both
///      powers are part of the trust model. See README.
contract ShareToken is ERC20Upgradeable, UpgradeTimelock {
    // ──────────── Constants ────────────

    /// @dev Expiry value meaning "whitelisted with no end date".
    uint64 public constant NO_EXPIRY = type(uint64).max;

    // ──────────── State ────────────

    address public complianceOfficer;

    /// @notice A wallet is whitelisted while this timestamp is in the future. 0 means never.
    mapping(address => uint64) public whitelistedUntil;

    /// @dev Reserved for future upgrades.
    uint256[50] private __gap;

    // ──────────── Events ────────────

    event ComplianceOfficerUpdated(address indexed oldOfficer, address indexed newOfficer);
    event WhitelistUpdated(address indexed account, uint64 until);

    // ──────────── Errors ────────────

    error OnlyComplianceOfficer();
    error NotWhitelisted(address account);

    // ──────────── Modifiers ────────────

    modifier onlyComplianceOfficer() {
        _checkComplianceOfficer();
        _;
    }

    // ──────────── Constructor / Initializer ────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address owner_,
        address complianceOfficer_,
        address guardian_
    ) external initializer {
        if (owner_ == address(0) || complianceOfficer_ == address(0)) revert ZeroAddress();
        __ERC20_init(name_, symbol_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        complianceOfficer = complianceOfficer_;
        emit ComplianceOfficerUpdated(address(0), complianceOfficer_);
        _setGuardian(guardian_);
    }

    // ══════════════════════════════════════════════════════════════
    //                    OWNER: CONFIGURATION
    // ══════════════════════════════════════════════════════════════

    function setComplianceOfficer(address newOfficer) external onlyOwner {
        if (newOfficer == address(0)) revert ZeroAddress();
        emit ComplianceOfficerUpdated(complianceOfficer, newOfficer);
        complianceOfficer = newOfficer;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn from any wallet, including a frozen one.
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    // ══════════════════════════════════════════════════════════════
    //                    COMPLIANCE: WHITELIST
    // ══════════════════════════════════════════════════════════════

    /// @notice Whitelist without an end date, or remove immediately.
    function setWhitelisted(address account, bool whitelisted) external onlyComplianceOfficer {
        _setWhitelistedUntil(account, whitelisted ? NO_EXPIRY : 0);
    }

    function setWhitelistedBatch(address[] calldata accounts, bool whitelisted) external onlyComplianceOfficer {
        uint64 until = whitelisted ? NO_EXPIRY : 0;
        for (uint256 i = 0; i < accounts.length; i++) {
            _setWhitelistedUntil(accounts[i], until);
        }
    }

    /// @notice Whitelist until `until`. A past or zero value removes the wallet.
    function setWhitelistedUntil(address account, uint64 until) external onlyComplianceOfficer {
        _setWhitelistedUntil(account, until);
    }

    // ══════════════════════════════════════════════════════════════
    //                    VIEWS
    // ══════════════════════════════════════════════════════════════

    function isWhitelisted(address account) public view returns (bool) {
        return whitelistedUntil[account] > block.timestamp;
    }

    // ──────────── Internal ────────────

    function _checkComplianceOfficer() internal view {
        if (msg.sender != complianceOfficer) revert OnlyComplianceOfficer();
    }

    function _setWhitelistedUntil(address account, uint64 until) internal {
        if (account == address(0)) revert ZeroAddress();
        whitelistedUntil[account] = until;
        emit WhitelistUpdated(account, until);
    }

    /// @dev Single choke point for mint, burn and transfer. A burn only needs the
    ///      sender check skipped, since the receiver is the zero address.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0) && !isWhitelisted(to)) revert NotWhitelisted(to);
        if (from != address(0) && to != address(0) && !isWhitelisted(from)) revert NotWhitelisted(from);
        super._update(from, to, value);
    }
}
