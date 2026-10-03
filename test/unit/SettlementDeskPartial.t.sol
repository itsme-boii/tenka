// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";
import {ShareToken} from "../../src/ShareToken.sol";

/// @notice Partial fills, whitelist expiry at fill time, and nonce reuse.
contract SettlementDeskPartialTest is HaldenTestBase {
    function _partial(uint256 shares, uint256 payment) internal view returns (ISettlementDesk.Order memory o) {
        o = _order(shares, payment);
        o.allowPartial = true;
    }

    // ══════════════════════════════════════════════════════════════
    //                    PRO RATA SETTLEMENT
    // ══════════════════════════════════════════════════════════════

    function test_partial_proRataThenExactRemainder() public {
        ISettlementDesk.Order memory o = _partial(100e18, 90e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 40e18, 36e6, 1, NAV, -1000, 0);
        vm.prank(buyer);
        desk.fill(o, sig, 40e18);

        (uint256 filled, uint256 paid) = desk.progress(seller, 1);
        assertEq(filled, 40e18);
        assertEq(paid, 36e6);
        assertFalse(desk.nonceUsed(seller, 1)); // still open

        vm.prank(buyer);
        desk.fill(o, sig, 60e18); // the last 60 settle at the exact remainder
        assertEq(usdc.balanceOf(seller), 90e6);
        assertEq(share.balanceOf(buyer), 100e18);
        assertTrue(desk.nonceUsed(seller, 1)); // closed once complete
    }

    function test_partial_roundsUpForTheSeller_totalIsExact() public {
        // 3 shares for 100 base units: 100/3 is not whole, so each part rounds up
        ISettlementDesk.Order memory o = _partial(3e18, 100);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.startPrank(buyer);
        desk.fill(o, sig, 1e18); // ceil(33.33) = 34
        assertEq(usdc.balanceOf(seller), 34);
        desk.fill(o, sig, 1e18); // another 34
        assertEq(usdc.balanceOf(seller), 68);
        desk.fill(o, sig, 1e18); // the remainder: 100 - 68 = 32
        vm.stopPrank();

        assertEq(usdc.balanceOf(seller), 100); // never more than the signed total
        assertTrue(desk.nonceUsed(seller, 1));
    }

    function test_RevertWhen_partialWouldPayNothing() public {
        // 1 base unit for 3 shares: the first part takes it all, so a later part owes zero
        ISettlementDesk.Order memory o = _partial(3e18, 1);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.startPrank(buyer);
        desk.fill(o, sig, 1e18); // pays 1
        vm.expectRevert(SettlementDesk.ZeroAmount.selector);
        desk.fill(o, sig, 1e18); // would pay 0 for a share
        vm.expectRevert(SettlementDesk.ZeroAmount.selector);
        desk.fill(o, sig, 2e18); // the last part would also pay 0
        vm.stopPrank();

        assertEq(share.balanceOf(buyer), 1e18); // no free shares were handed out
    }

    function test_partial_eachPartIsNeverBelowSignedPrice() public {
        ISettlementDesk.Order memory o = _partial(7e18, 1_000_003);
        bytes memory sig = _sign(sellerPk, desk, o);
        uint256 filledSoFar;
        uint256 paidSoFar;
        uint256[3] memory parts = [uint256(2e18), 3e18, 2e18];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(buyer);
            desk.fill(o, sig, parts[i]);
            filledSoFar += parts[i];
            paidSoFar = usdc.balanceOf(seller);
            assertGe(paidSoFar * o.shares, filledSoFar * o.payment); // cumulative price >= signed price
        }
        assertEq(paidSoFar, o.payment);
    }

    function test_partial_fullFillOfPartialOrderClosesIt() public {
        ISettlementDesk.Order memory o = _partial(10e18, 10e6);
        _fill(o);
        assertTrue(desk.nonceUsed(seller, 1));
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NonceAlreadyUsed.selector);
        desk.fill(o, sig, 1e18);
    }

    function test_partial_differentBuyersFillTheSameOrder() public {
        uint256 buyer2Pk = 0xB2;
        address buyer2 = vm.addr(buyer2Pk);
        vm.prank(compliance);
        share.setWhitelisted(buyer2, true);
        usdc.mint(buyer2, 1_000e6);
        vm.prank(buyer2);
        usdc.approve(address(desk), type(uint256).max);

        ISettlementDesk.Order memory o = _partial(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        desk.fill(o, sig, 30e18);
        vm.prank(buyer2);
        desk.fill(o, sig, 70e18);

        assertEq(share.balanceOf(buyer), 30e18);
        assertEq(share.balanceOf(buyer2), 70e18);
        assertEq(usdc.balanceOf(seller), 100e6);
    }

    // ══════════════════════════════════════════════════════════════
    //                    REJECTIONS
    // ══════════════════════════════════════════════════════════════

    function test_RevertWhen_partialOfNonPartialOrder() public {
        ISettlementDesk.Order memory o = _order(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.PartialNotAllowed.selector);
        desk.fill(o, sig, 99e18);
    }

    function test_RevertWhen_fillSharesZero() public {
        ISettlementDesk.Order memory o = _partial(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.ZeroAmount.selector);
        desk.fill(o, sig, 0);
    }

    function test_RevertWhen_fillExceedsRemaining() public {
        ISettlementDesk.Order memory o = _partial(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.startPrank(buyer);
        vm.expectRevert(SettlementDesk.ExceedsRemaining.selector);
        desk.fill(o, sig, 101e18);
        desk.fill(o, sig, 60e18);
        vm.expectRevert(SettlementDesk.ExceedsRemaining.selector);
        desk.fill(o, sig, 41e18);
        vm.stopPrank();
    }

    function test_RevertWhen_partialFlagChangedAfterSigning() public {
        ISettlementDesk.Order memory o = _order(100e18, 100e6); // signed as all-or-nothing
        bytes memory sig = _sign(sellerPk, desk, o);
        o.allowPartial = true; // a buyer flips it to take less
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, 1e18);
    }

    function test_cancel_closesPartiallyFilledOrder() public {
        ISettlementDesk.Order memory o = _partial(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        desk.fill(o, sig, 25e18);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        vm.prank(seller);
        desk.cancel(nonces);

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NonceAlreadyUsed.selector);
        desk.fill(o, sig, 25e18);
        assertEq(share.balanceOf(buyer), 25e18); // what was filled stays settled
    }

    function test_partial_failedLegRollsBackProgress() public {
        ISettlementDesk.Order memory o = _partial(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(seller);
        share.approve(address(desk), 0); // the share leg will fail

        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, 40e18);

        (uint256 filled, uint256 paid) = desk.progress(seller, 1);
        assertEq(filled, 0);
        assertEq(paid, 0);
        assertEq(usdc.balanceOf(seller), 0);
    }

    // ══════════════════════════════════════════════════════════════
    //                    NONCE REUSE
    // ══════════════════════════════════════════════════════════════

    function test_RevertWhen_nonceReusedForSmallerOrder() public {
        ISettlementDesk.Order memory a = _partial(100e18, 90e6);
        _fillShares(a, 60e18);

        ISettlementDesk.Order memory b = _partial(50e18, 45e6); // same nonce, 50 < 60 already filled
        bytes memory sig = _sign(sellerPk, desk, b);
        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.ExceedsRemaining.selector);
        desk.fill(b, sig, 1e18);
    }

    function test_nonceReusedForBiggerOrder_continuesFromProgress() public {
        ISettlementDesk.Order memory a = _partial(100e18, 90e6);
        _fillShares(a, 60e18); // pays 54e6

        ISettlementDesk.Order memory b = _partial(200e18, 200e6); // the seller's own mistake
        _fillShares(b, 140e18); // 140 remain, and 146e6 is still unpaid on b
        assertEq(usdc.balanceOf(seller), 54e6 + 146e6);
        assertTrue(desk.nonceUsed(seller, 1));
    }

    // ══════════════════════════════════════════════════════════════
    //                    WHITELIST EXPIRY AT FILL TIME
    // ══════════════════════════════════════════════════════════════

    function test_RevertWhen_sellerWhitelistExpiredBeforeFill() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(seller, uint64(T0 + 1 hours));
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + 1 hours);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, seller));
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_buyerWhitelistExpiredBeforeFill() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, uint64(T0 + 1 hours));
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + 1 hours);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, buyer));
        desk.fill(o, sig, o.shares);
    }

    function test_fill_whileWhitelistStillValid() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, uint64(T0 + 1 hours));
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.warp(T0 + 1 hours - 1);
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
        assertEq(share.balanceOf(buyer), 1e18);
    }
}
