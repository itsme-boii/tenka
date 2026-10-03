// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ISettlementDesk} from "./interfaces/ISettlementDesk.sol";
import {INavOracle} from "./interfaces/INavOracle.sol";
import {IShareToken} from "./interfaces/IShareToken.sol";
import {UpgradeTimelock} from "./UpgradeTimelock.sol";

/// @title SettlementDesk — atomic share-for-stablecoin settlement at any price
/// @notice A whitelisted seller signs an order (shares, total payment, optional buyer,
///         optional NAV guards, optional partial fills). A whitelisted buyer fills it.
///         The stablecoin goes to the seller and the shares go to the buyer in one
///         transaction, or neither moves. The NAV is read at fill time and logged with
///         the premium or discount in bps. It never limits the price.
/// @dev Stateless: the desk never holds shares or stablecoin between transactions. The
///      buyer's stablecoin moves only when the buyer is `msg.sender`. The seller's shares
///      move only against a valid, unexpired signature from the seller.
///      Partial fills charge `payment * fillShares / shares` rounded up, capped at what is
///      still unpaid, and the final fill takes the exact remainder. The seller therefore
///      never receives less than the signed price per share, and the total never exceeds
///      the signed payment.
contract SettlementDesk is
    ISettlementDesk,
    UpgradeTimelock,
    PausableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    // ──────────── Constants ────────────

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address seller,address buyer,uint256 shares,uint256 payment,uint64 navEpoch,uint64 maxNavAge,bool allowPartial,uint256 nonce,uint256 deadline)"
    );
    uint256 internal constant SHARE_UNIT = 1e18;
    int256 internal constant BPS = 10_000;

    // ──────────── Immutables ────────────

    IShareToken public immutable shareToken;
    IERC20 public immutable stablecoin;
    INavOracle public immutable navOracle;

    // ──────────── State ────────────

    /// @dev What has been taken from one order so far.
    struct Progress {
        uint256 shares;
        uint256 paid;
    }

    /// @dev The NAV as seen by one fill.
    struct NavView {
        uint64 epoch;
        uint128 navPerShare;
        uint64 age;
    }

    /// @notice True once an order is fully filled or cancelled.
    mapping(address seller => mapping(uint256 nonce => bool)) public nonceUsed;

    /// @notice Shares taken and stablecoin paid so far, per order.
    mapping(address seller => mapping(uint256 nonce => Progress)) public progress;

    /// @dev Reserved for future upgrades.
    uint256[50] private __gap;

    // ──────────── Events ────────────

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed seller,
        address indexed buyer,
        uint256 shares,
        uint256 payment,
        uint64 navEpoch,
        uint128 navPerShare,
        int256 premiumBps,
        uint64 navAge
    );
    event OrderCancelled(address indexed seller, uint256 indexed nonce);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ──────────── Errors ────────────

    error DeadlineExpired();
    error WrongBuyer();
    error SelfTrade();
    error ZeroAmount();
    error PartialNotAllowed();
    error ExceedsRemaining();
    error NotWhitelisted(address account);
    error NonceAlreadyUsed();
    error NoNav();
    error NavEpochMismatch();
    error NavTooOld();
    error InvalidSignature();
    error UnexpectedBalanceChange();

    // ──────────── Constructor / Initializer ────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address shareToken_, address stablecoin_, address navOracle_) {
        if (shareToken_ == address(0) || stablecoin_ == address(0) || navOracle_ == address(0)) revert ZeroAddress();
        shareToken = IShareToken(shareToken_);
        stablecoin = IERC20(stablecoin_);
        navOracle = INavOracle(navOracle_);
        _disableInitializers();
    }

    function initialize(address owner_, address guardian_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __EIP712_init("Halden SettlementDesk", "1");
        _setGuardian(guardian_);
    }

    // ══════════════════════════════════════════════════════════════
    //                    SETTLEMENT
    // ══════════════════════════════════════════════════════════════

    /// @notice Fill `fillShares` of a seller's signed order. The caller is the buyer.
    /// @dev An order without `allowPartial` must be filled in full.
    function fill(Order calldata order, bytes calldata signature, uint256 fillShares)
        external
        whenNotPaused
        nonReentrant
    {
        bytes32 orderHash = hashOrder(order);
        NavView memory nav = _validate(order, orderHash, signature, fillShares);
        uint256 payment = _account(order, fillShares);

        // Both legs are verified by balance delta, so a hostile token cannot short either side.
        _pull(stablecoin, msg.sender, order.seller, payment);
        _pull(IERC20(address(shareToken)), order.seller, msg.sender, fillShares);

        emit OrderFilled(
            orderHash,
            order.seller,
            msg.sender,
            fillShares,
            payment,
            nav.epoch,
            nav.navPerShare,
            _premiumBps(payment, fillShares, nav.navPerShare),
            nav.age
        );
    }

    /// @notice Void the caller's own nonces. Works while paused, so intent can always be withdrawn.
    function cancel(uint256[] calldata nonces) external {
        for (uint256 i = 0; i < nonces.length; i++) {
            nonceUsed[msg.sender][nonces[i]] = true;
            emit OrderCancelled(msg.sender, nonces[i]);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                    OWNER: ADMIN
    // ══════════════════════════════════════════════════════════════

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover tokens sent here by mistake. The desk never legitimately holds any,
    ///         and rescue is allowed only while paused.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // ══════════════════════════════════════════════════════════════
    //                    VIEWS
    // ══════════════════════════════════════════════════════════════

    function hashOrder(Order calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.seller,
                    order.buyer,
                    order.shares,
                    order.payment,
                    order.navEpoch,
                    order.maxNavAge,
                    order.allowPartial,
                    order.nonce,
                    order.deadline
                )
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ──────────── Internal ────────────

    /// @dev Every check that does not change state. Returns the NAV the fill is priced against.
    function _validate(Order calldata order, bytes32 orderHash, bytes calldata signature, uint256 fillShares)
        internal
        view
        returns (NavView memory nav)
    {
        if (block.timestamp > order.deadline) revert DeadlineExpired();
        if (order.buyer != address(0) && order.buyer != msg.sender) revert WrongBuyer();
        if (msg.sender == order.seller) revert SelfTrade();
        if (order.shares == 0 || order.payment == 0 || fillShares == 0) revert ZeroAmount();
        if (!order.allowPartial && fillShares != order.shares) revert PartialNotAllowed();
        if (!shareToken.isWhitelisted(order.seller)) revert NotWhitelisted(order.seller);
        if (!shareToken.isWhitelisted(msg.sender)) revert NotWhitelisted(msg.sender);
        if (nonceUsed[order.seller][order.nonce]) revert NonceAlreadyUsed();

        uint64 asOf;
        (nav.epoch, nav.navPerShare, asOf,) = navOracle.latest();
        if (nav.epoch == 0) revert NoNav();
        if (order.navEpoch != 0 && order.navEpoch != nav.epoch) revert NavEpochMismatch();
        nav.age = uint64(block.timestamp) - asOf;
        if (order.maxNavAge != 0 && nav.age > order.maxNavAge) revert NavTooOld();

        if (!SignatureChecker.isValidSignatureNow(order.seller, orderHash, signature)) revert InvalidSignature();
    }

    /// @dev Records the fill and returns the stablecoin owed. Closes the order when its
    ///      last share is taken.
    function _account(Order calldata order, uint256 fillShares) internal returns (uint256 payment) {
        Progress storage p = progress[order.seller][order.nonce];

        uint256 remaining = order.shares > p.shares ? order.shares - p.shares : 0;
        if (fillShares > remaining) revert ExceedsRemaining();
        uint256 unpaid = order.payment > p.paid ? order.payment - p.paid : 0;

        if (fillShares == remaining) {
            payment = unpaid;
            nonceUsed[order.seller][order.nonce] = true;
        } else {
            payment = Math.min(Math.mulDiv(order.payment, fillShares, order.shares, Math.Rounding.Ceil), unpaid);
        }
        if (payment == 0) revert ZeroAmount();

        p.shares += fillShares;
        p.paid += payment;
    }

    /// @dev Moves `amount` from `from` to `to` and reverts unless the receiver's balance
    ///      rose by exactly `amount`. This rejects fee-on-transfer tokens.
    function _pull(IERC20 token, address from, address to, uint256 amount) internal {
        uint256 before = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        if (token.balanceOf(to) - before != amount) revert UnexpectedBalanceChange();
    }

    /// @dev Negative means a discount to NAV. The price is `payment * 1e18 / shares`.
    function _premiumBps(uint256 payment, uint256 shares, uint128 navPerShare) internal pure returns (int256) {
        int256 price = SafeCast.toInt256(Math.mulDiv(payment, SHARE_UNIT, shares));
        int256 nav = int256(uint256(navPerShare));
        return (price - nav) * BPS / nav;
    }
}
