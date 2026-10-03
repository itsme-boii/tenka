// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";
import {UpgradeTimelock} from "../../src/UpgradeTimelock.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {MockReentrantToken} from "../mocks/MockReentrantToken.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";

contract SettlementDeskUnitTest is HaldenTestBase {
    // ══════════════════════════════════════════════════════════════
    //                    HAPPY PATHS
    // ══════════════════════════════════════════════════════════════

    function test_fill_atPar() public {
        ISettlementDesk.Order memory o = _order(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 100e18, 100e6, 1, NAV, 0, 0);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);

        assertEq(share.balanceOf(buyer), 100e18);
        assertEq(share.balanceOf(seller), 900e18);
        assertEq(usdc.balanceOf(seller), 100e6);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6 - 100e6);
        assertTrue(desk.nonceUsed(seller, 1));
    }

    function test_fill_atDiscount_negativePremium() public {
        ISettlementDesk.Order memory o = _order(100e18, 61e6); // 0.61 per share: a 39% discount
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 100e18, 61e6, 1, NAV, -3900, 0);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
    }

    function test_fill_atPremium_positivePremium() public {
        ISettlementDesk.Order memory o = _order(100e18, 105e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 100e18, 105e6, 1, NAV, 500, 0);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
    }

    function test_fill_recordsNavAge() public {
        skip(2 days);
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 1e18, 1e6, 1, NAV, 0, 2 days);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
    }

    function test_fill_namedBuyer() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.buyer = buyer;
        _fill(o);
        assertEq(share.balanceOf(buyer), 1e18);
    }

    function test_fill_deskHoldsNothingAfter() public {
        _fill(_order(10e18, 7e6));
        assertEq(share.balanceOf(address(desk)), 0);
        assertEq(usdc.balanceOf(address(desk)), 0);
    }

    function test_fill_withNavGuards_whenSatisfied() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.navEpoch = 1;
        o.maxNavAge = 7 days;
        skip(1 days);
        _fill(o);
        assertEq(share.balanceOf(buyer), 1e18);
    }

    function test_fill_deadlineBoundaryInclusive() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.deadline = block.timestamp;
        _fill(o);
    }

    function test_fill_manyOrdersOpenAtOnce() public {
        ISettlementDesk.Order memory a = _order(1e18, 1e6);
        ISettlementDesk.Order memory b = _order(2e18, 2e6);
        b.nonce = 99;
        _fill(b);
        _fill(a);
        assertEq(share.balanceOf(buyer), 3e18);
    }

    // ══════════════════════════════════════════════════════════════
    //                    REJECTIONS
    // ══════════════════════════════════════════════════════════════

    function test_RevertWhen_deadlineExpired() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        skip(1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.DeadlineExpired.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_wrongBuyer() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.buyer = address(0x1234);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.WrongBuyer.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_selfTrade() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(seller);
        vm.expectRevert(SettlementDesk.SelfTrade.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_zeroShares() public {
        ISettlementDesk.Order memory o = _order(0, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.ZeroAmount.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_zeroPayment() public {
        ISettlementDesk.Order memory o = _order(1e18, 0);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.ZeroAmount.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_sellerNotWhitelisted() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(compliance);
        share.setWhitelisted(seller, false);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, seller));
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_buyerNotWhitelisted() public {
        vm.prank(compliance);
        share.setWhitelisted(buyer, false);
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, buyer));
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_replayed() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.startPrank(buyer);
        desk.fill(o, sig, o.shares);
        vm.expectRevert(SettlementDesk.NonceAlreadyUsed.selector);
        desk.fill(o, sig, o.shares);
        vm.stopPrank();
    }

    function test_RevertWhen_cancelled() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = o.nonce;

        vm.expectEmit(true, true, false, false, address(desk));
        emit SettlementDesk.OrderCancelled(seller, o.nonce);
        vm.prank(seller);
        desk.cancel(nonces);

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NonceAlreadyUsed.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_badSignature() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(buyerPk, desk, o); // signed by someone else
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_orderTamperedAfterSigning() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        o.payment = 1; // buyer tries to underpay
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_garbageSignature() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, hex"deadbeef", o.shares);
    }

    function test_RevertWhen_signedForAnotherDesk() public {
        SettlementDesk other = _deployDesk(address(share), address(usdc), address(oracle));
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, other, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_signedOnAnotherChain() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.chainId(block.chainid + 1);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_paused() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        desk.pause();
        vm.prank(buyer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        desk.fill(o, sig, o.shares);

        desk.unpause();
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
    }

    function test_cancel_worksWhilePaused() public {
        desk.pause();
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 7;
        vm.prank(seller);
        desk.cancel(nonces);
        assertTrue(desk.nonceUsed(seller, 7));
    }

    function test_cancel_onlyAffectsCaller() public {
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        vm.prank(outsider);
        desk.cancel(nonces); // burns outsider's nonce 1, not the seller's
        assertFalse(desk.nonceUsed(seller, 1));
        _fill(_order(1e18, 1e6));
    }

    function test_RevertWhen_noNavPosted() public {
        NavOracle fresh = NavOracle(
            _proxy(address(new NavOracle()), abi.encodeCall(NavOracle.initialize, (owner, agent, 2000, 0, guardian)))
        );
        SettlementDesk d = _deployDesk(address(share), address(usdc), address(fresh));
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, d, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NoNav.selector);
        d.fill(o, sig, o.shares);
    }

    function test_RevertWhen_navEpochMovedOn() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.navEpoch = 1;
        o.deadline = T0 + 30 days;
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + 6 days);
        vm.prank(agent);
        oracle.postNav(1_100_000, uint64(T0 + 6 days));

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NavEpochMismatch.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_navCorrectedUnderOrder() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.navEpoch = 1;
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + 1 hours);
        vm.prank(agent);
        oracle.correctLatest(1_100_000); // a correction is a new epoch, so the old order dies

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NavEpochMismatch.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_navTooOld() public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.maxNavAge = 1 days;
        o.deadline = T0 + 30 days;
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + 1 days);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares); // exactly at the limit still fills

        o.nonce = 2;
        sig = _sign(sellerPk, desk, o);
        vm.warp(T0 + 1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NavTooOld.selector);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_noShareAllowance() public {
        vm.prank(seller);
        share.approve(address(desk), 0);
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, o.shares);
        // atomic: the stablecoin leg was rolled back too
        assertEq(usdc.balanceOf(seller), 0);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6);
        assertFalse(desk.nonceUsed(seller, 1));
    }

    function test_RevertWhen_noStablecoinAllowance() public {
        vm.prank(buyer);
        usdc.approve(address(desk), 0);
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, o.shares);
        assertEq(share.balanceOf(buyer), 0);
    }

    function test_RevertWhen_sellerHasTooFewShares() public {
        ISettlementDesk.Order memory o = _order(1_001e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, o.shares);
        assertEq(usdc.balanceOf(seller), 0); // payment rolled back
    }

    // ══════════════════════════════════════════════════════════════
    //                    HOSTILE TOKENS AND WALLETS
    // ══════════════════════════════════════════════════════════════

    function test_RevertWhen_feeOnTransferStablecoin() public {
        MockFeeOnTransferToken fee = new MockFeeOnTransferToken();
        SettlementDesk d = _deployDesk(address(share), address(fee), address(oracle));
        fee.mint(buyer, 1_000e6);
        vm.prank(buyer);
        fee.approve(address(d), type(uint256).max);
        vm.prank(seller);
        share.approve(address(d), type(uint256).max);

        ISettlementDesk.Order memory o = _order(1e18, 100e6);
        bytes memory sig = _sign(sellerPk, d, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.UnexpectedBalanceChange.selector);
        d.fill(o, sig, o.shares);
    }

    function test_reentrantStablecoin_cannotReenterFill() public {
        MockReentrantToken re = new MockReentrantToken();
        SettlementDesk d = _deployDesk(address(share), address(re), address(oracle));
        re.mint(buyer, 1_000e6);
        vm.prank(buyer);
        re.approve(address(d), type(uint256).max);
        vm.prank(seller);
        share.approve(address(d), type(uint256).max);

        ISettlementDesk.Order memory o = _order(1e18, 100e6);
        o.nonce = 5;
        bytes memory sig = _sign(sellerPk, d, o);
        // the token tries to fill the same order again from inside the transfer
        re.arm(address(d), abi.encodeCall(SettlementDesk.fill, (o, sig, o.shares)));

        vm.prank(buyer);
        d.fill(o, sig, o.shares);

        assertTrue(re.attempted());
        assertFalse(re.succeeded());
        assertEq(bytes4(re.revertData()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        assertEq(share.balanceOf(buyer), 1e18); // filled exactly once
    }

    function test_fill_erc1271Seller() public {
        address walletOwner = vm.addr(0xA11CE);
        MockERC1271Wallet wallet = new MockERC1271Wallet(walletOwner);

        vm.prank(compliance);
        share.setWhitelisted(address(wallet), true);
        share.mint(address(wallet), 10e18);
        vm.prank(walletOwner);
        wallet.execute(address(share), abi.encodeCall(share.approve, (address(desk), type(uint256).max)));

        ISettlementDesk.Order memory o = _order(10e18, 9e6);
        o.seller = address(wallet);
        bytes memory sig = _sign(0xA11CE, desk, o); // the wallet's owner signs

        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
        assertEq(share.balanceOf(buyer), 10e18);
        assertEq(usdc.balanceOf(address(wallet)), 9e6);
    }

    function test_RevertWhen_erc1271WalletRejects() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(vm.addr(0xA11CE));
        vm.prank(compliance);
        share.setWhitelisted(address(wallet), true);
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.seller = address(wallet);
        bytes memory sig = _sign(0xBEEF, desk, o); // not the wallet's owner
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    // ══════════════════════════════════════════════════════════════
    //                    ADMIN
    // ══════════════════════════════════════════════════════════════

    function test_rescueToken_onlyWhilePaused() public {
        usdc.mint(address(desk), 5e6);
        vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
        desk.rescueToken(address(usdc), owner, 5e6);

        desk.pause();
        desk.rescueToken(address(usdc), owner, 5e6);
        assertEq(usdc.balanceOf(owner), 5e6);
    }

    function test_RevertWhen_rescueToZeroAddress() public {
        desk.pause();
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        desk.rescueToken(address(usdc), address(0), 1);
    }

    function test_RevertWhen_nonOwnerAdmin() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        desk.pause();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        desk.unpause();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        desk.rescueToken(address(usdc), outsider, 1);
        vm.stopPrank();
    }

    function test_RevertWhen_constructorZeroAddress() public {
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        new SettlementDesk(address(0), address(usdc), address(oracle));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        new SettlementDesk(address(share), address(0), address(oracle));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        new SettlementDesk(address(share), address(usdc), address(0));
    }

    function test_RevertWhen_initializeZeroOwner() public {
        address impl = address(new SettlementDesk(address(share), address(usdc), address(oracle)));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        this.deployProxy(impl, abi.encodeCall(SettlementDesk.initialize, (address(0), guardian)));
    }

    function test_RevertWhen_reinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        desk.initialize(owner, guardian);
    }

    function test_domainSeparator_matchesEip712() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Halden SettlementDesk"),
                keccak256("1"),
                block.chainid,
                address(desk)
            )
        );
        assertEq(desk.DOMAIN_SEPARATOR(), expected);
    }

    function deployProxy(address impl, bytes memory data) external returns (address) {
        return _proxy(impl, data);
    }
}
