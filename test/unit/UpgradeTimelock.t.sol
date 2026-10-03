// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {UpgradeTimelock} from "../../src/UpgradeTimelock.sol";

/// @notice The timelock is shared by all three contracts. NavOracle is the test host,
///         and the last tests confirm the other two behave the same way.
contract UpgradeTimelockUnitTest is HaldenTestBase {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    NavOracle internal newImpl;

    function setUp() public override {
        super.setUp();
        newImpl = new NavOracle();
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function test_queueThenUpgrade_afterDelay() public {
        oracle.queueUpgrade(address(newImpl));
        (address queued, uint64 eta) = oracle.queuedUpgrade();
        assertEq(queued, address(newImpl));
        assertEq(eta, block.timestamp + 48 hours);

        vm.warp(T0 + 48 hours);
        oracle.upgradeToAndCall(address(newImpl), "");
        assertEq(_impl(address(oracle)), address(newImpl));

        // state survives, and the queue entry is consumed
        (uint64 epoch,,,) = oracle.latest();
        assertEq(epoch, 1);
        (queued,) = oracle.queuedUpgrade();
        assertEq(queued, address(0));
    }

    function test_RevertWhen_upgradeNotQueued() public {
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_RevertWhen_upgradeTooEarly() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 48 hours - 1);
        vm.expectRevert(UpgradeTimelock.UpgradeTooEarly.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_RevertWhen_upgradeWindowExpired() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 48 hours + 7 days + 1);
        vm.expectRevert(UpgradeTimelock.UpgradeWindowExpired.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_lastSecondOfWindow() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 48 hours + 7 days);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_RevertWhen_differentImplementationThanQueued() public {
        oracle.queueUpgrade(address(newImpl));
        NavOracle other = new NavOracle();
        vm.warp(T0 + 48 hours);
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(other), "");
    }

    function test_RevertWhen_upgradeReplayed() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 48 hours);
        oracle.upgradeToAndCall(address(newImpl), "");
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_queueAgain_replacesAndRestartsDelay() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 47 hours);
        NavOracle other = new NavOracle();
        oracle.queueUpgrade(address(other));

        vm.warp(T0 + 48 hours); // the first entry's eta, but it was replaced
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
        vm.expectRevert(UpgradeTimelock.UpgradeTooEarly.selector);
        oracle.upgradeToAndCall(address(other), "");
    }

    function test_cancel() public {
        oracle.queueUpgrade(address(newImpl));
        vm.expectEmit(true, true, false, false, address(oracle));
        emit UpgradeTimelock.UpgradeCancelled(address(newImpl), owner);
        oracle.cancelUpgrade();

        vm.warp(T0 + 48 hours);
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(newImpl), "");

        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.cancelUpgrade();
    }

    function test_RevertWhen_queueInvalid() public {
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        oracle.queueUpgrade(address(0));
        vm.expectRevert(UpgradeTimelock.NotAContract.selector);
        oracle.queueUpgrade(address(0x1234));
    }

    function test_RevertWhen_nonOwnerTouchesQueue() public {
        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        oracle.queueUpgrade(address(newImpl));
        vm.expectRevert(UpgradeTimelock.OnlyOwnerOrGuardian.selector);
        oracle.cancelUpgrade();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        oracle.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();
    }

    function test_RevertWhen_nonOwnerUpgradesQueuedImplementation() public {
        oracle.queueUpgrade(address(newImpl));
        vm.warp(T0 + 48 hours);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_RevertWhen_upgradingImplementationDirectly() public {
        // the implementation itself is not a usable upgrade target: UUPS checks the proxy context
        vm.expectRevert();
        newImpl.upgradeToAndCall(address(newImpl), "");
    }

    function test_desk_sameTimelock() public {
        SettlementDesk newDesk = new SettlementDesk(address(share), address(usdc), address(oracle));
        desk.queueUpgrade(address(newDesk));
        vm.warp(T0 + 48 hours);
        desk.upgradeToAndCall(address(newDesk), "");
        assertEq(_impl(address(desk)), address(newDesk));
        _fillAfterUpgrade();
    }

    function test_shareToken_sameTimelock() public {
        ShareToken newToken = new ShareToken();
        share.queueUpgrade(address(newToken));
        vm.expectRevert(UpgradeTimelock.UpgradeTooEarly.selector);
        share.upgradeToAndCall(address(newToken), "");
        vm.warp(T0 + 48 hours);
        share.upgradeToAndCall(address(newToken), "");
        assertEq(share.balanceOf(seller), 1_000e18);
        assertTrue(share.isWhitelisted(seller));
    }

    // ──────────── Guardian ────────────

    function test_guardian_isSetAtInitialize() public view {
        assertEq(oracle.guardian(), guardian);
        assertEq(desk.guardian(), guardian);
        assertEq(share.guardian(), guardian);
    }

    function test_guardian_canCancelQueuedUpgrade() public {
        oracle.queueUpgrade(address(newImpl));
        vm.expectEmit(true, true, false, false, address(oracle));
        emit UpgradeTimelock.UpgradeCancelled(address(newImpl), guardian);
        vm.prank(guardian);
        oracle.cancelUpgrade();

        vm.warp(T0 + 48 hours);
        vm.expectRevert(UpgradeTimelock.UpgradeNotQueued.selector);
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function test_RevertWhen_guardianQueuesOrUpgrades() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guardian));
        oracle.queueUpgrade(address(newImpl));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guardian));
        oracle.upgradeToAndCall(address(newImpl), "");
        vm.stopPrank();
    }

    function test_setGuardian_ownerOnly() public {
        vm.expectEmit(true, true, false, false, address(oracle));
        emit UpgradeTimelock.GuardianUpdated(guardian, outsider);
        oracle.setGuardian(outsider);
        assertEq(oracle.guardian(), outsider);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guardian));
        oracle.setGuardian(guardian);
    }

    function test_zeroGuardian_meansOnlyOwnerCancels() public {
        oracle.setGuardian(address(0));
        oracle.queueUpgrade(address(newImpl));
        vm.prank(address(0)); // an unset guardian must not match the zero address
        vm.expectRevert(UpgradeTimelock.OnlyOwnerOrGuardian.selector);
        oracle.cancelUpgrade();
        vm.prank(guardian); // the old guardian lost the role
        vm.expectRevert(UpgradeTimelock.OnlyOwnerOrGuardian.selector);
        oracle.cancelUpgrade();
        oracle.cancelUpgrade();
    }

    function _fillAfterUpgrade() internal {
        _fill(_order(1e18, 1e6));
        assertEq(share.balanceOf(buyer), 1e18);
    }
}
