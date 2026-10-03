// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {UpgradeTimelock} from "../../src/UpgradeTimelock.sol";

contract NavOracleUnitTest is HaldenTestBase {
    function test_firstPost_recorded() public view {
        (uint64 epoch, uint128 nav, uint64 asOf, uint64 postedAt) = oracle.latest();
        assertEq(epoch, 1);
        assertEq(nav, NAV);
        assertEq(asOf, T0);
        assertEq(postedAt, T0);
        assertEq(oracle.epochCount(), 1);
    }

    function test_latest_emptyOracle() public {
        NavOracle fresh = NavOracle(
            _proxy(address(new NavOracle()), abi.encodeCall(NavOracle.initialize, (owner, agent, 2000, 0, guardian)))
        );
        (uint64 epoch,,,) = fresh.latest();
        assertEq(epoch, 0);
        vm.expectRevert(NavOracle.NoNav.selector);
        fresh.navAge();
    }

    function test_navAge_tracksAsOf() public {
        skip(3 days);
        assertEq(oracle.navAge(), 3 days);
    }

    function test_weeklyPost_afterInterval() public {
        skip(6 days);
        vm.prank(agent);
        oracle.postNav(1_100_000, uint64(block.timestamp));
        (uint64 epoch, uint128 nav,,) = oracle.latest();
        assertEq(epoch, 2);
        assertEq(nav, 1_100_000);
        (uint128 oldNav,,) = oracle.navAt(1);
        assertEq(oldNav, NAV);
    }

    function test_RevertWhen_notAgent() public {
        vm.expectRevert(NavOracle.OnlyValuationAgent.selector);
        oracle.postNav(1, 1);
        vm.expectRevert(NavOracle.OnlyValuationAgent.selector);
        oracle.correctLatest(1);
    }

    function test_RevertWhen_zeroNav() public {
        skip(6 days);
        vm.startPrank(agent);
        vm.expectRevert(NavOracle.ZeroNav.selector);
        oracle.postNav(0, uint64(block.timestamp));
        vm.expectRevert(NavOracle.ZeroNav.selector);
        oracle.correctLatest(0);
        vm.stopPrank();
    }

    function test_RevertWhen_asOfInFuture() public {
        skip(6 days);
        vm.prank(agent);
        vm.expectRevert(NavOracle.AsOfInFuture.selector);
        oracle.postNav(NAV, uint64(block.timestamp + 1));
    }

    function test_RevertWhen_asOfNotIncreasing() public {
        skip(6 days);
        vm.prank(agent);
        vm.expectRevert(NavOracle.AsOfNotIncreasing.selector);
        oracle.postNav(NAV, uint64(T0));
    }

    function test_RevertWhen_postTooSoon() public {
        skip(5 days);
        vm.prank(agent);
        vm.expectRevert(NavOracle.PostTooSoon.selector);
        oracle.postNav(NAV, uint64(block.timestamp));
    }

    function test_RevertWhen_changeTooLarge() public {
        skip(6 days);
        vm.startPrank(agent);
        vm.expectRevert(NavOracle.ChangeTooLarge.selector);
        oracle.postNav(1_200_001, uint64(block.timestamp)); // +20.0001%
        vm.expectRevert(NavOracle.ChangeTooLarge.selector);
        oracle.postNav(799_999, uint64(block.timestamp)); // -20.0001%
        oracle.postNav(1_200_000, uint64(block.timestamp)); // exactly +20% is allowed
        vm.stopPrank();
    }

    function test_correctLatest_appendsNewEpoch() public {
        skip(6 days);
        vm.prank(agent);
        oracle.postNav(1_100_000, uint64(block.timestamp));
        (,, uint64 asOf2, uint64 postedAt2) = oracle.latest();

        skip(1 hours);
        vm.prank(agent);
        oracle.correctLatest(1_050_000);

        (uint64 epoch, uint128 nav, uint64 asOf, uint64 postedAt) = oracle.latest();
        assertEq(epoch, 3);
        assertEq(nav, 1_050_000);
        assertEq(asOf, asOf2);
        assertEq(postedAt, postedAt2);
        (uint128 oldNav,,) = oracle.navAt(2);
        assertEq(oldNav, 1_100_000); // the mistaken epoch is preserved
    }

    function test_correctLatest_guardedAgainstOriginalBase() public {
        skip(6 days);
        vm.startPrank(agent);
        oracle.postNav(1_100_000, uint64(block.timestamp));
        vm.expectRevert(NavOracle.ChangeTooLarge.selector);
        oracle.correctLatest(1_300_000); // +30% against epoch 1, not against the bad post
        vm.stopPrank();
    }

    function test_correctLatest_firstEpochHasNoBase() public {
        vm.prank(agent);
        oracle.correctLatest(5_000_000);
        (, uint128 nav,,) = oracle.latest();
        assertEq(nav, 5_000_000);
    }

    function test_correctLatest_doesNotResetPostInterval() public {
        vm.warp(T0 + 6 days);
        vm.prank(agent);
        oracle.postNav(1_100_000, uint64(T0 + 6 days));
        vm.warp(T0 + 6 days + 23 hours);
        vm.prank(agent);
        oracle.correctLatest(1_050_000);
        vm.warp(T0 + 12 days); // 6 days after the ORIGINAL post, not after the correction
        vm.prank(agent);
        oracle.postNav(1_080_000, uint64(T0 + 12 days));
        assertEq(oracle.epochCount(), 4);
    }

    function test_RevertWhen_correctionWindowClosed() public {
        skip(24 hours + 1);
        vm.prank(agent);
        vm.expectRevert(NavOracle.CorrectionWindowClosed.selector);
        oracle.correctLatest(NAV);
    }

    function test_RevertWhen_correctWithNoNav() public {
        NavOracle fresh = NavOracle(
            _proxy(address(new NavOracle()), abi.encodeCall(NavOracle.initialize, (owner, agent, 2000, 0, guardian)))
        );
        vm.prank(agent);
        vm.expectRevert(NavOracle.NoNav.selector);
        fresh.correctLatest(1);
    }

    function test_RevertWhen_navAtOutOfRange() public {
        vm.expectRevert(NavOracle.EpochOutOfRange.selector);
        oracle.navAt(0);
        vm.expectRevert(NavOracle.EpochOutOfRange.selector);
        oracle.navAt(2);
    }

    function test_setMaxChangeBps_bounded() public {
        oracle.setMaxChangeBps(5000);
        assertEq(oracle.maxChangeBps(), 5000);
        vm.expectRevert(NavOracle.InvalidMaxChange.selector);
        oracle.setMaxChangeBps(5001);
        vm.expectRevert(NavOracle.InvalidMaxChange.selector);
        oracle.setMaxChangeBps(0);
    }

    function test_RevertWhen_initializeBadMaxChange() public {
        address impl = address(new NavOracle());
        vm.expectRevert(NavOracle.InvalidMaxChange.selector);
        this.deployProxy(impl, abi.encodeCall(NavOracle.initialize, (owner, agent, 0, 0, guardian)));
        vm.expectRevert(NavOracle.InvalidMaxChange.selector);
        this.deployProxy(impl, abi.encodeCall(NavOracle.initialize, (owner, agent, 5001, 0, guardian)));
    }

    function test_RevertWhen_initializeZeroAddress() public {
        address impl = address(new NavOracle());
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        this.deployProxy(impl, abi.encodeCall(NavOracle.initialize, (address(0), agent, 2000, 0, guardian)));
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        this.deployProxy(impl, abi.encodeCall(NavOracle.initialize, (owner, address(0), 2000, 0, guardian)));
    }

    function test_setValuationAgent() public {
        oracle.setValuationAgent(outsider);
        assertEq(oracle.valuationAgent(), outsider);
        vm.expectRevert(UpgradeTimelock.ZeroAddress.selector);
        oracle.setValuationAgent(address(0));

        // old agent loses access
        skip(6 days);
        vm.prank(agent);
        vm.expectRevert(NavOracle.OnlyValuationAgent.selector);
        oracle.postNav(NAV, uint64(block.timestamp));
    }

    function test_RevertWhen_reinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(owner, agent, 2000, 0, guardian);
    }

    function deployProxy(address impl, bytes memory data) external returns (address) {
        return _proxy(impl, data);
    }
}
