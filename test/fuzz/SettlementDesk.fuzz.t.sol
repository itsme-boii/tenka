// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";

contract SettlementDeskFuzzTest is HaldenTestBase {
    function testFuzz_fill_anyPrice_settlesAtomically(uint256 shares, uint256 payment) public {
        shares = bound(shares, 1, 1_000e18);
        payment = bound(payment, 1, 1e30);
        usdc.mint(buyer, payment);

        uint256 sellerShares = share.balanceOf(seller);
        uint256 buyerUsdc = usdc.balanceOf(buyer);
        uint256 supply = share.totalSupply();

        _fill(_order(shares, payment));

        assertEq(share.balanceOf(seller), sellerShares - shares);
        assertEq(share.balanceOf(buyer), shares);
        assertEq(usdc.balanceOf(seller), payment);
        assertEq(usdc.balanceOf(buyer), buyerUsdc - payment);
        assertEq(share.totalSupply(), supply);
        assertEq(share.balanceOf(address(desk)), 0);
        assertEq(usdc.balanceOf(address(desk)), 0);
    }

    function testFuzz_fill_buyerShortOfFunds_revertsWholly(uint256 shares, uint256 payment) public {
        shares = bound(shares, 1, 1_000e18);
        payment = bound(payment, 1_000_000e6 + 1, 1e30); // more than the buyer holds
        ISettlementDesk.Order memory o = _order(shares, payment);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, o.shares);

        assertEq(share.balanceOf(seller), 1_000e18);
        assertEq(share.balanceOf(buyer), 0);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6);
        assertFalse(desk.nonceUsed(seller, 1));
    }

    function testFuzz_fill_premiumBps_signMatchesPrice(uint256 shares, uint256 payment) public {
        shares = bound(shares, 1e12, 1_000e18);
        payment = bound(payment, 1, 1e24);
        usdc.mint(buyer, payment);

        vm.recordLogs();
        _fill(_order(shares, payment));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory filled = logs[logs.length - 1];
        assertEq(filled.topics[0], SettlementDesk.OrderFilled.selector);
        (,,,, int256 premiumBps,) = abi.decode(filled.data, (uint256, uint256, uint64, uint128, int256, uint64));

        uint256 price = payment * 1e18 / shares;
        if (price > NAV) assertGe(premiumBps, 0);
        else if (price < NAV) assertLe(premiumBps, 0);
        else assertEq(premiumBps, 0);
        assertGe(premiumBps, -10_000); // a price can never be below zero
    }

    function testFuzz_fill_navAgeGuard(uint256 wait, uint64 maxAge) public {
        wait = bound(wait, 0, 60 days);
        maxAge = uint64(bound(uint256(maxAge), 0, 60 days));

        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.maxNavAge = maxAge;
        o.deadline = T0 + 90 days;
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.warp(T0 + wait);
        vm.prank(buyer);
        if (maxAge != 0 && wait > maxAge) vm.expectRevert(SettlementDesk.NavTooOld.selector);
        desk.fill(o, sig, o.shares);
    }

    function testFuzz_fill_whitelistState(bool sellerListed, bool buyerListed) public {
        vm.startPrank(compliance);
        share.setWhitelisted(seller, sellerListed);
        share.setWhitelisted(buyer, buyerListed);
        vm.stopPrank();

        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.prank(buyer);
        if (!sellerListed) vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, seller));
        else if (!buyerListed) vm.expectRevert(abi.encodeWithSelector(SettlementDesk.NotWhitelisted.selector, buyer));
        desk.fill(o, sig, o.shares);

        assertEq(share.balanceOf(buyer) > 0, sellerListed && buyerListed);
    }

    function testFuzz_fill_signatureBoundToEveryField(uint8 field) public {
        field = uint8(bound(field, 0, 5));
        ISettlementDesk.Order memory o = _order(5e18, 5e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        if (field == 0) o.shares += 1;
        else if (field == 1) o.payment -= 1;
        else if (field == 2) o.nonce += 1;
        else if (field == 3) o.deadline += 1;
        else if (field == 4) o.navEpoch = 1;
        else o.maxNavAge = 1 days;

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.InvalidSignature.selector);
        desk.fill(o, sig, o.shares);
    }

    function testFuzz_cancel_thenFillAlwaysReverts(uint256 nonce) public {
        ISettlementDesk.Order memory o = _order(1e18, 1e6);
        o.nonce = nonce;
        bytes memory sig = _sign(sellerPk, desk, o);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        vm.prank(seller);
        desk.cancel(nonces);

        vm.prank(buyer);
        vm.expectRevert(SettlementDesk.NonceAlreadyUsed.selector);
        desk.fill(o, sig, o.shares);
    }

    function testFuzz_partialFills_neverUnderpayAndNeverOverpay(uint256 shares, uint256 payment, uint256 seed) public {
        shares = bound(shares, 1, 1_000e18);
        payment = bound(payment, 1, 1e24);
        usdc.mint(buyer, payment);

        ISettlementDesk.Order memory o = _order(shares, payment);
        o.allowPartial = true;
        bytes memory sig = _sign(sellerPk, desk, o);

        uint256 filled;
        for (uint256 i = 0; i < 6 && filled < shares; i++) {
            uint256 remaining = shares - filled;
            uint256 part = i == 5 ? remaining : bound(uint256(keccak256(abi.encode(seed, i))), 1, remaining);

            vm.prank(buyer);
            try desk.fill(o, sig, part) {
                filled += part;
            } catch {
                break; // a part that would pay nothing is rejected, which is fine
            }

            uint256 paid = usdc.balanceOf(seller);
            assertLe(paid, payment, "overpaid");
            assertGe(paid * shares, filled * payment, "paid below the signed price");
            assertEq(share.balanceOf(buyer), filled);
        }
        if (filled == shares) assertEq(usdc.balanceOf(seller), payment, "complete order must pay exactly the total");
    }

    function testFuzz_partial_notAllowed_onlyFullFill(uint256 fillShares) public {
        fillShares = bound(fillShares, 1, 1_000e18);
        ISettlementDesk.Order memory o = _order(500e18, 500e6);
        bytes memory sig = _sign(sellerPk, desk, o);

        vm.prank(buyer);
        if (fillShares != o.shares) vm.expectRevert(SettlementDesk.PartialNotAllowed.selector);
        desk.fill(o, sig, fillShares);
    }
}
