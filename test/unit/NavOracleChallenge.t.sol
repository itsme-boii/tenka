// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";
import {UpgradeTimelock} from "../../src/UpgradeTimelock.sol";

/// @notice A proposed NAV waits out a challenge window, and the guardian can veto it.
contract NavOracleChallengeTest is HaldenTestBase {
    uint256 internal constant WINDOW = 6 hours;

    function setUp() public override {
        super.setUp(); // epoch 1 is live, posted with no window
        oracle.setChallengeWindow(WINDOW);
    }

    function _propose(uint128 nav) internal returns (uint64 at) {
        vm.warp(T0 + 6 days);
        vm.prank(agent);
        oracle.postNav(nav, uint64(T0 + 6 days));
        at = uint64(T0 + 6 days + WINDOW);
    }

    // ──────────── Post, wait, activate ────────────

    function test_post_isPendingNotLive() public {
        vm.expectEmit(false, false, false, true, address(oracle));
        emit NavOracle.NavProposed(1_100_000, uint64(T0 + 6 days), uint64(T0 + 6 days + WINDOW), false);
        uint64 at = _propose(1_100_000);

        (uint128 nav, uint64 asOf, uint64 baseEpoch, uint64 activatesAt, bool correction) = oracle.pending();
        assertEq(nav, 1_100_000);
        assertEq(asOf, T0 + 6 days);
        assertEq(baseEpoch, 1);
        assertEq(activatesAt, at);
        assertFalse(correction);

        (uint64 epoch, uint128 live,,) = oracle.latest();
        assertEq(epoch, 1);
        assertEq(live, NAV); // the old NAV stays live
        assertEq(oracle.epochCount(), 1);
    }

    function test_activate_afterWindow_byAnyone() public {
        uint64 at = _propose(1_100_000);
        vm.warp(at);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit NavOracle.NavPosted(2, 1_100_000, uint64(T0 + 6 days));
        vm.prank(outsider);
        oracle.activatePending();

        (uint64 epoch, uint128 nav, uint64 asOf, uint64 postedAt) = oracle.latest();
        assertEq(epoch, 2);
        assertEq(nav, 1_100_000);
        assertEq(asOf, T0 + 6 days);
        assertEq(postedAt, at); // the interval and correction window run from going live
        (,,, uint64 activatesAt,) = oracle.pending();
        assertEq(activatesAt, 0);
    }

    function test_RevertWhen_activateEarly() public {
        uint64 at = _propose(1_100_000);
        vm.warp(at - 1);
        vm.expectRevert(NavOracle.ChallengeWindowOpen.selector);
        oracle.activatePending();
    }

    function test_RevertWhen_activateWithNothingPending() public {
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.activatePending();
    }

    function test_fill_usesLiveNavWhileAnotherIsPending() public {
        _propose(1_100_000);
        ISettlementDesk.Order memory o = _order(100e18, 100e6);
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.expectEmit(true, true, true, true, address(desk));
        emit SettlementDesk.OrderFilled(desk.hashOrder(o), seller, buyer, 100e18, 100e6, 1, NAV, 0, uint64(6 days));
        vm.prank(buyer);
        desk.fill(o, sig, o.shares);
    }

    function test_RevertWhen_postOrCorrectWhilePending() public {
        _propose(1_100_000);
        vm.startPrank(agent);
        vm.expectRevert(NavOracle.PendingNavExists.selector);
        oracle.postNav(1_100_000, uint64(T0 + 6 days));
        vm.expectRevert(NavOracle.PendingNavExists.selector);
        oracle.correctLatest(1_050_000);
        vm.stopPrank();
    }

    function test_nextPost_intervalRunsFromActivation() public {
        uint64 at = _propose(1_100_000);
        vm.warp(at);
        oracle.activatePending();

        vm.warp(at + 6 days - 1);
        vm.prank(agent);
        vm.expectRevert(NavOracle.PostTooSoon.selector);
        oracle.postNav(1_150_000, uint64(at + 6 days - 1));

        vm.warp(at + 6 days);
        vm.prank(agent);
        oracle.postNav(1_150_000, uint64(at + 6 days));
    }

    // ──────────── Veto and withdraw ────────────

    function test_guardian_canVeto() public {
        _propose(1_100_000);
        vm.expectEmit(false, true, false, true, address(oracle));
        emit NavOracle.NavVetoed(1_100_000, guardian);
        vm.prank(guardian);
        oracle.vetoPending();

        (,,, uint64 activatesAt,) = oracle.pending();
        assertEq(activatesAt, 0);
        vm.warp(T0 + 6 days + WINDOW);
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.activatePending();
        assertEq(oracle.epochCount(), 1);
    }

    function test_owner_canVeto() public {
        _propose(1_100_000);
        oracle.vetoPending();
        assertEq(oracle.epochCount(), 1);
    }

    function test_RevertWhen_otherVetoes() public {
        _propose(1_100_000);
        vm.prank(outsider);
        vm.expectRevert(UpgradeTimelock.OnlyOwnerOrGuardian.selector);
        oracle.vetoPending();
        vm.prank(agent); // the agent cannot veto its own post
        vm.expectRevert(UpgradeTimelock.OnlyOwnerOrGuardian.selector);
        oracle.vetoPending();
    }

    function test_RevertWhen_vetoWithNothingPending() public {
        vm.prank(guardian);
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.vetoPending();
    }

    function test_agent_canRepostAfterVeto() public {
        _propose(1_100_000);
        vm.prank(guardian);
        oracle.vetoPending();
        vm.prank(agent);
        oracle.postNav(1_050_000, uint64(T0 + 6 days));
        (uint128 nav,,,,) = oracle.pending();
        assertEq(nav, 1_050_000);
    }

    function test_agent_canWithdrawOwnPending() public {
        _propose(1_100_000);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit NavOracle.NavWithdrawn(1_100_000);
        vm.prank(agent);
        oracle.withdrawPending();
        (,,, uint64 activatesAt,) = oracle.pending();
        assertEq(activatesAt, 0);
    }

    function test_RevertWhen_withdrawNotAgentOrNothingPending() public {
        vm.prank(agent);
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.withdrawPending();

        _propose(1_100_000);
        vm.prank(guardian);
        vm.expectRevert(NavOracle.OnlyValuationAgent.selector);
        oracle.withdrawPending();
    }

    // ──────────── Corrections go through the window ────────────

    function test_correction_isPendingThenAppendsEpoch() public {
        uint64 at = _propose(1_100_000);
        vm.warp(at);
        oracle.activatePending();

        vm.warp(at + 23 hours); // inside 24h of going live
        vm.prank(agent);
        oracle.correctLatest(1_050_000);
        (,,, uint64 activatesAt, bool correction) = oracle.pending();
        assertEq(activatesAt, at + 23 hours + WINDOW);
        assertTrue(correction);
        (, uint128 live,,) = oracle.latest();
        assertEq(live, 1_100_000); // the mistaken NAV stays live until the correction activates

        vm.warp(at + 23 hours + WINDOW);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit NavOracle.NavCorrected(3, 2, 1_050_000);
        oracle.activatePending();

        (uint64 epoch, uint128 nav, uint64 asOf, uint64 postedAt) = oracle.latest();
        assertEq(epoch, 3);
        assertEq(nav, 1_050_000);
        assertEq(asOf, T0 + 6 days);
        assertEq(postedAt, at); // keeps the replaced epoch's timing
    }

    function test_RevertWhen_correctionWindowClosedAfterActivation() public {
        uint64 at = _propose(1_100_000);
        vm.warp(at);
        oracle.activatePending();
        vm.warp(at + 24 hours + 1);
        vm.prank(agent);
        vm.expectRevert(NavOracle.CorrectionWindowClosed.selector);
        oracle.correctLatest(1_050_000);
    }

    function test_guardian_canVetoCorrection() public {
        vm.prank(agent);
        oracle.correctLatest(900_000);
        vm.prank(guardian);
        oracle.vetoPending();
        (, uint128 live,,) = oracle.latest();
        assertEq(live, NAV);
        assertEq(oracle.epochCount(), 1);
    }

    // ──────────── Configuration ────────────

    function test_setChallengeWindow_bounded() public {
        vm.expectEmit(false, false, false, true, address(oracle));
        emit NavOracle.ChallengeWindowUpdated(WINDOW, 3 days);
        oracle.setChallengeWindow(3 days);
        assertEq(oracle.challengeWindow(), 3 days);
        vm.expectRevert(NavOracle.InvalidChallengeWindow.selector);
        oracle.setChallengeWindow(3 days + 1);
    }

    function test_zeroWindow_goesLiveImmediately() public {
        oracle.setChallengeWindow(0);
        vm.warp(T0 + 6 days);
        vm.prank(agent);
        oracle.postNav(1_100_000, uint64(T0 + 6 days));
        assertEq(oracle.epochCount(), 2);
        (,,, uint64 activatesAt,) = oracle.pending();
        assertEq(activatesAt, 0);
    }

    function test_windowChange_doesNotMovePendingTime() public {
        uint64 at = _propose(1_100_000);
        oracle.setChallengeWindow(3 days);
        (,,, uint64 activatesAt,) = oracle.pending();
        assertEq(activatesAt, at);
    }

    function test_RevertWhen_initializeWindowTooLong() public {
        address impl = address(new NavOracle());
        vm.expectRevert(NavOracle.InvalidChallengeWindow.selector);
        this.deployProxy(impl, abi.encodeCall(NavOracle.initialize, (owner, agent, 2000, 3 days + 1, guardian)));
    }

    function deployProxy(address impl, bytes memory data) external returns (address) {
        return _proxy(impl, data);
    }
}
