// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {UpgradeTimelock} from "../../src/UpgradeTimelock.sol";

contract ShareTokenUnitTest is HaldenTestBase {
    function test_metadata() public view {
        assertEq(share.name(), "Halden Fund Share");
        assertEq(share.symbol(), "HLD");
        assertEq(share.decimals(), 18);
    }

    function test_mint_toWhitelisted() public {
        share.mint(buyer, 5e18);
        assertEq(share.balanceOf(buyer), 5e18);
    }

    function test_RevertWhen_mintToNonWhitelisted() public {
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, outsider));
        share.mint(outsider, 1e18);
    }

    function test_transfer_betweenWhitelisted() public {
        vm.prank(seller);
        share.transfer(buyer, 10e18);
        assertEq(share.balanceOf(buyer), 10e18);
    }

    function test_RevertWhen_transferToNonWhitelisted() public {
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, outsider));
        share.transfer(outsider, 1e18);
    }

    function test_RevertWhen_transferFromNonWhitelisted() public {
        vm.prank(compliance);
        share.setWhitelisted(seller, false);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, seller));
        share.transfer(buyer, 1e18);
    }

    function test_removedWallet_isFrozen_untilReAdded() public {
        vm.prank(compliance);
        share.setWhitelisted(seller, false);
        assertEq(share.balanceOf(seller), 1_000e18); // balance is kept, only frozen
        vm.prank(seller);
        share.approve(buyer, 1e18);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, seller));
        share.transferFrom(seller, buyer, 1e18);

        vm.prank(compliance);
        share.setWhitelisted(seller, true);
        vm.prank(seller);
        share.transfer(buyer, 1e18);
    }

    function test_batchWhitelist() public {
        address[] memory a = new address[](2);
        a[0] = address(0x11);
        a[1] = address(0x22);
        vm.prank(compliance);
        share.setWhitelistedBatch(a, true);
        assertTrue(share.isWhitelisted(a[0]));
        assertTrue(share.isWhitelisted(a[1]));
    }

    function test_RevertWhen_whitelistZeroAddress() public {
        vm.prank(compliance);
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        share.setWhitelisted(address(0), true);
    }

    function test_RevertWhen_nonOfficerSetsWhitelist() public {
        vm.prank(outsider);
        vm.expectRevert(ShareToken.OnlyComplianceOfficer.selector);
        share.setWhitelisted(outsider, true);

        // the owner is not the officer either
        vm.expectRevert(ShareToken.OnlyComplianceOfficer.selector);
        share.setWhitelisted(outsider, true);
    }

    function test_RevertWhen_nonOwnerMintsOrBurns() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        share.mint(outsider, 1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        share.burn(seller, 1);
        vm.stopPrank();
    }

    function test_burn_byOwner() public {
        share.burn(seller, 100e18);
        assertEq(share.balanceOf(seller), 900e18);
        assertEq(share.totalSupply(), 900e18);
    }

    function test_ownerCannotMoveHolderShares() public {
        // no forceTransfer exists, and the owner has no allowance
        vm.expectRevert();
        share.transferFrom(seller, buyer, 1e18);
    }

    function test_setComplianceOfficer() public {
        share.setComplianceOfficer(outsider);
        assertEq(share.complianceOfficer(), outsider);
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        share.setComplianceOfficer(address(0));
    }

    function test_twoStepOwnership() public {
        share.transferOwnership(outsider);
        assertEq(share.owner(), owner);
        vm.prank(outsider);
        share.acceptOwnership();
        assertEq(share.owner(), outsider);
    }

    // ──────────── Whitelist expiry ────────────

    function test_whitelist_noExpiryByDefault() public view {
        assertEq(share.whitelistedUntil(seller), share.NO_EXPIRY());
        assertTrue(share.isWhitelisted(seller));
    }

    function test_whitelistExpiry_freezesAtTheBoundary() public {
        uint64 until = uint64(T0 + 1 days);
        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, until);
        assertTrue(share.isWhitelisted(buyer));

        vm.warp(until - 1);
        vm.prank(seller);
        share.transfer(buyer, 1e18); // still whitelisted one second before

        vm.warp(until); // `until` itself is already expired
        assertFalse(share.isWhitelisted(buyer));
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, buyer));
        share.transfer(buyer, 1e18);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, buyer));
        share.transfer(seller, 1e18);
    }

    function test_whitelistExpiry_canBeRenewed() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, uint64(T0 + 1 days));
        vm.warp(T0 + 2 days);
        assertFalse(share.isWhitelisted(buyer));

        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, uint64(T0 + 3 days));
        assertTrue(share.isWhitelisted(buyer));
    }

    function test_RevertWhen_mintToExpiredWallet() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(buyer, uint64(T0 + 1));
        vm.warp(T0 + 1);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, buyer));
        share.mint(buyer, 1e18);
    }

    function test_setWhitelistedUntil_pastOrZeroRemoves() public {
        vm.startPrank(compliance);
        share.setWhitelistedUntil(buyer, 0);
        assertFalse(share.isWhitelisted(buyer));
        share.setWhitelistedUntil(buyer, uint64(block.timestamp)); // not in the future
        assertFalse(share.isWhitelisted(buyer));
        vm.stopPrank();
    }

    function test_whitelistUpdated_emitsUntil() public {
        vm.expectEmit(true, false, false, true, address(share));
        emit ShareToken.WhitelistUpdated(outsider, 12_345);
        vm.prank(compliance);
        share.setWhitelistedUntil(outsider, 12_345);

        vm.expectEmit(true, false, false, true, address(share));
        emit ShareToken.WhitelistUpdated(outsider, 0);
        vm.prank(compliance);
        share.setWhitelisted(outsider, false);
    }

    function test_RevertWhen_nonOfficerSetsExpiry() public {
        vm.prank(outsider);
        vm.expectRevert(ShareToken.OnlyComplianceOfficer.selector);
        share.setWhitelistedUntil(outsider, type(uint64).max);
    }

    // ──────────── Burning from frozen wallets ────────────

    function test_burn_fromFrozenWallet() public {
        vm.prank(compliance);
        share.setWhitelisted(seller, false);
        share.burn(seller, 400e18);
        assertEq(share.balanceOf(seller), 600e18);
        assertEq(share.totalSupply(), 600e18);
    }

    function test_burn_fromExpiredWallet() public {
        vm.prank(compliance);
        share.setWhitelistedUntil(seller, uint64(T0 + 1));
        vm.warp(T0 + 1);
        share.burn(seller, 1e18);
        assertEq(share.balanceOf(seller), 999e18);
    }

    function test_frozenWallet_stillCannotTransferOut() public {
        vm.prank(compliance);
        share.setWhitelisted(seller, false);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(ShareToken.NotWhitelisted.selector, seller));
        share.transfer(buyer, 1e18);
    }

    function test_RevertWhen_reinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        share.initialize("x", "x", owner, compliance, guardian);
    }

    function test_RevertWhen_initializeImplementation() public {
        ShareToken impl = new ShareToken();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("x", "x", owner, compliance, guardian);
    }

    function test_RevertWhen_initializeZeroAddress() public {
        ShareToken impl = new ShareToken();
        bytes memory bad = abi.encodeCall(ShareToken.initialize, ("x", "x", address(0), compliance, guardian));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        this.deployProxy(address(impl), bad);
        bad = abi.encodeCall(ShareToken.initialize, ("x", "x", owner, address(0), guardian));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        this.deployProxy(address(impl), bad);
    }

    function deployProxy(address impl, bytes memory data) external returns (address) {
        return _proxy(impl, data);
    }
}
