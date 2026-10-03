// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HaldenTestBase} from "../helpers/HaldenTestBase.sol";
import {NavOracle} from "../../src/NavOracle.sol";

contract NavOracleFuzzTest is HaldenTestBase {
    function testFuzz_postNav_respectsChangeGuard(uint128 next) public {
        next = uint128(bound(uint256(next), 1, 1e13));
        vm.warp(T0 + 6 days);

        uint256 diff = next > NAV ? next - NAV : NAV - next;
        bool allowed = diff * 10_000 <= uint256(NAV) * 2000;

        vm.prank(agent);
        if (!allowed) vm.expectRevert(NavOracle.ChangeTooLarge.selector);
        oracle.postNav(next, uint64(T0 + 6 days));

        (, uint128 nav,,) = oracle.latest();
        assertEq(nav, allowed ? next : NAV);
    }

    function testFuzz_postNav_intervalAndAsOf(uint256 wait, uint64 asOfBack) public {
        wait = bound(wait, 0, 30 days);
        vm.warp(T0 + wait);
        asOfBack = uint64(bound(uint256(asOfBack), 0, wait));
        uint64 asOf = uint64(T0 + wait - asOfBack);

        bool tooSoon = wait < 6 days;
        bool notIncreasing = asOf <= T0;

        vm.prank(agent);
        if (notIncreasing) vm.expectRevert(NavOracle.AsOfNotIncreasing.selector);
        else if (tooSoon) vm.expectRevert(NavOracle.PostTooSoon.selector);
        oracle.postNav(NAV, asOf);
    }

    function testFuzz_correctLatest_window(uint256 wait, uint128 corrected) public {
        wait = bound(wait, 0, 3 days);
        corrected = uint128(bound(uint256(corrected), 1, 1e13));
        vm.warp(T0 + wait);

        vm.prank(agent);
        if (wait > 24 hours) vm.expectRevert(NavOracle.CorrectionWindowClosed.selector);
        oracle.correctLatest(corrected); // the first epoch has no change guard

        assertEq(oracle.epochCount(), wait > 24 hours ? 1 : 2);
    }

    function testFuzz_maxChangeBps_neverAboveCap(uint256 bps) public {
        if (bps == 0 || bps > 5000) vm.expectRevert(NavOracle.InvalidMaxChange.selector);
        oracle.setMaxChangeBps(bps);
        assertLe(oracle.maxChangeBps(), 5000);
        assertGt(oracle.maxChangeBps(), 0);
    }
}
