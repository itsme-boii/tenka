// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INavOracle} from "./interfaces/INavOracle.sol";
import {UpgradeTimelock} from "./UpgradeTimelock.sol";

/// @title NavOracle — weekly NAV posted by a trusted valuation agent, with a veto window
/// @notice The NAV is a reference price. It never limits what price a trade can settle at.
///         A posted NAV waits out a challenge window before it goes live, and the
///         guardian (or owner) can veto it in that time. Epoch `n` is `_history[n - 1]`,
///         so epoch 0 means "no NAV yet".
/// @dev `navPerShare` is stablecoin base units per 1e18 share units (1_000_000 = 1.00 USDC
///      per share). A correction goes through the same window and appends a new epoch
///      instead of editing the old one, so an order bound to the mistaken epoch stops
///      filling and can never be silently re-priced. With `challengeWindow == 0` a post or
///      correction goes live at once. The oracle is deliberately not pausable: stopping
///      the NAV feed is never the right response to an incident.
contract NavOracle is INavOracle, UpgradeTimelock {
    // ──────────── Constants ────────────

    uint256 public constant MIN_POST_INTERVAL = 6 days;
    uint256 public constant CORRECTION_WINDOW = 24 hours;
    uint256 public constant MAX_CHANGE_CAP_BPS = 5000;
    uint256 public constant MAX_CHALLENGE_WINDOW = 3 days;
    uint256 internal constant BPS = 10_000;

    // ──────────── State ────────────

    /// @dev `baseEpoch` is the epoch the change guard compared against (0 for the first post).
    ///      A correction inherits it from the epoch it replaces.
    struct NavPoint {
        uint128 navPerShare;
        uint64 asOf;
        uint64 postedAt;
        uint64 baseEpoch;
    }

    /// @dev `activatesAt == 0` means nothing is pending. A correction keeps the replaced
    ///      epoch's `asOf` and `postedAt` when it activates.
    struct PendingNav {
        uint128 navPerShare;
        uint64 asOf;
        uint64 baseEpoch;
        uint64 activatesAt;
        bool correction;
    }

    address public valuationAgent;
    uint256 public maxChangeBps;
    uint256 public challengeWindow;
    /// @notice The NAV waiting out its challenge window. `activatesAt == 0` means none.
    PendingNav public pending;
    NavPoint[] internal _history;

    /// @dev Reserved for future upgrades.
    uint256[50] private __gap;

    // ──────────── Events ────────────

    event NavProposed(uint128 navPerShare, uint64 asOf, uint64 activatesAt, bool correction);
    event NavPosted(uint64 indexed epoch, uint128 navPerShare, uint64 asOf);
    event NavCorrected(uint64 indexed epoch, uint64 indexed replacedEpoch, uint128 navPerShare);
    event NavVetoed(uint128 navPerShare, address indexed by);
    event NavWithdrawn(uint128 navPerShare);
    event ValuationAgentUpdated(address indexed oldAgent, address indexed newAgent);
    event MaxChangeBpsUpdated(uint256 oldBps, uint256 newBps);
    event ChallengeWindowUpdated(uint256 oldWindow, uint256 newWindow);

    // ──────────── Errors ────────────

    error OnlyValuationAgent();
    error ZeroNav();
    error AsOfInFuture();
    error AsOfNotIncreasing();
    error PostTooSoon();
    error ChangeTooLarge();
    error InvalidMaxChange();
    error InvalidChallengeWindow();
    error NoNav();
    error CorrectionWindowClosed();
    error EpochOutOfRange();
    error PendingNavExists();
    error NoPendingNav();
    error ChallengeWindowOpen();

    // ──────────── Modifiers ────────────

    modifier onlyValuationAgent() {
        if (msg.sender != valuationAgent) revert OnlyValuationAgent();
        _;
    }

    // ──────────── Constructor / Initializer ────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address valuationAgent_,
        uint256 maxChangeBps_,
        uint256 challengeWindow_,
        address guardian_
    ) external initializer {
        if (owner_ == address(0) || valuationAgent_ == address(0)) revert ZeroAddress();
        if (maxChangeBps_ == 0 || maxChangeBps_ > MAX_CHANGE_CAP_BPS) revert InvalidMaxChange();
        if (challengeWindow_ > MAX_CHALLENGE_WINDOW) revert InvalidChallengeWindow();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        valuationAgent = valuationAgent_;
        maxChangeBps = maxChangeBps_;
        challengeWindow = challengeWindow_;
        emit ValuationAgentUpdated(address(0), valuationAgent_);
        emit MaxChangeBpsUpdated(0, maxChangeBps_);
        emit ChallengeWindowUpdated(0, challengeWindow_);
        _setGuardian(guardian_);
    }

    // ══════════════════════════════════════════════════════════════
    //                    OWNER: CONFIGURATION
    // ══════════════════════════════════════════════════════════════

    function setValuationAgent(address newAgent) external onlyOwner {
        if (newAgent == address(0)) revert ZeroAddress();
        emit ValuationAgentUpdated(valuationAgent, newAgent);
        valuationAgent = newAgent;
    }

    function setMaxChangeBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > MAX_CHANGE_CAP_BPS) revert InvalidMaxChange();
        emit MaxChangeBpsUpdated(maxChangeBps, newBps);
        maxChangeBps = newBps;
    }

    /// @notice Applies to proposals made after the change. A pending NAV keeps its own time.
    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow > MAX_CHALLENGE_WINDOW) revert InvalidChallengeWindow();
        emit ChallengeWindowUpdated(challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    // ══════════════════════════════════════════════════════════════
    //                    AGENT: NAV
    // ══════════════════════════════════════════════════════════════

    /// @notice Post the weekly NAV. `asOf` is the valuation timestamp.
    function postNav(uint128 navPerShare, uint64 asOf) external onlyValuationAgent {
        if (navPerShare == 0) revert ZeroNav();
        if (asOf > block.timestamp) revert AsOfInFuture();
        if (pending.activatesAt != 0) revert PendingNavExists();

        uint256 n = _history.length;
        uint64 baseEpoch;
        if (n > 0) {
            NavPoint storage last = _history[n - 1];
            if (asOf <= last.asOf) revert AsOfNotIncreasing();
            if (block.timestamp < uint256(last.postedAt) + MIN_POST_INTERVAL) revert PostTooSoon();
            _checkChange(last.navPerShare, navPerShare);
            baseEpoch = uint64(n);
        }

        _propose(PendingNav(navPerShare, asOf, baseEpoch, 0, false));
    }

    /// @notice Fix a mistaken latest NAV within `CORRECTION_WINDOW` of it going live.
    function correctLatest(uint128 navPerShare) external onlyValuationAgent {
        if (navPerShare == 0) revert ZeroNav();
        if (pending.activatesAt != 0) revert PendingNavExists();
        uint256 n = _history.length;
        if (n == 0) revert NoNav();

        NavPoint storage last = _history[n - 1];
        if (block.timestamp > uint256(last.postedAt) + CORRECTION_WINDOW) revert CorrectionWindowClosed();
        if (last.baseEpoch != 0) _checkChange(_history[last.baseEpoch - 1].navPerShare, navPerShare);

        _propose(PendingNav(navPerShare, last.asOf, last.baseEpoch, 0, true));
    }

    /// @notice Cancel the agent's own pending NAV, for example to repost a fixed value.
    function withdrawPending() external onlyValuationAgent {
        PendingNav memory p = pending;
        if (p.activatesAt == 0) revert NoPendingNav();
        delete pending;
        emit NavWithdrawn(p.navPerShare);
    }

    // ══════════════════════════════════════════════════════════════
    //                    CHALLENGE WINDOW
    // ══════════════════════════════════════════════════════════════

    /// @notice Make the pending NAV live once its window has passed. Anyone may call.
    function activatePending() external {
        PendingNav memory p = pending;
        if (p.activatesAt == 0) revert NoPendingNav();
        if (block.timestamp < p.activatesAt) revert ChallengeWindowOpen();
        delete pending;
        _activate(p);
    }

    /// @notice Reject the pending NAV. The guardian or the owner may call this.
    function vetoPending() external onlyOwnerOrGuardian {
        PendingNav memory p = pending;
        if (p.activatesAt == 0) revert NoPendingNav();
        delete pending;
        emit NavVetoed(p.navPerShare, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //                    VIEWS
    // ══════════════════════════════════════════════════════════════

    /// @inheritdoc INavOracle
    function latest() public view returns (uint64 epoch, uint128 navPerShare, uint64 asOf, uint64 postedAt) {
        uint256 n = _history.length;
        if (n == 0) return (0, 0, 0, 0);
        NavPoint storage p = _history[n - 1];
        return (uint64(n), p.navPerShare, p.asOf, p.postedAt);
    }

    function navAt(uint64 epoch) external view returns (uint128 navPerShare, uint64 asOf, uint64 postedAt) {
        if (epoch == 0 || epoch > _history.length) revert EpochOutOfRange();
        NavPoint storage p = _history[epoch - 1];
        return (p.navPerShare, p.asOf, p.postedAt);
    }

    /// @inheritdoc INavOracle
    function navAge() external view returns (uint64) {
        (uint64 epoch,, uint64 asOf,) = latest();
        if (epoch == 0) revert NoNav();
        return uint64(block.timestamp) - asOf;
    }

    function epochCount() external view returns (uint256) {
        return _history.length;
    }

    // ──────────── Internal ────────────

    /// @dev Goes live at once when there is no challenge window, otherwise waits.
    function _propose(PendingNav memory p) internal {
        if (challengeWindow == 0) {
            _activate(p);
            return;
        }
        p.activatesAt = uint64(block.timestamp + challengeWindow);
        pending = p;
        emit NavProposed(p.navPerShare, p.asOf, p.activatesAt, p.correction);
    }

    function _activate(PendingNav memory p) internal {
        uint256 n = _history.length;
        uint64 postedAt = uint64(block.timestamp);
        if (p.correction) postedAt = _history[n - 1].postedAt;

        _history.push(NavPoint({navPerShare: p.navPerShare, asOf: p.asOf, postedAt: postedAt, baseEpoch: p.baseEpoch}));
        if (p.correction) emit NavCorrected(uint64(n + 1), uint64(n), p.navPerShare);
        else emit NavPosted(uint64(n + 1), p.navPerShare, p.asOf);
    }

    function _checkChange(uint128 from, uint128 to) internal view {
        uint256 diff = from > to ? from - to : to - from;
        if (diff * BPS > uint256(from) * maxChangeBps) revert ChangeTooLarge();
    }
}
