// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Drives the whole system with random fills (full and partial), cancels, NAV
///         proposals, vetoes and activations, whitelist changes with expiry, pauses and
///         time jumps. Calls are wrapped in try/catch, so rejected actions are just
///         no-ops and only the invariants matter.
/// @dev An order's terms are a pure function of its nonce, because the desk keys fill
///      progress by (seller, nonce) and a nonce stands for one order.
contract SettlementDeskHandler is Test {
    SettlementDesk public desk;
    ShareToken public share;
    NavOracle public oracle;
    MockUSDC public usdc;

    address public compliance;
    address public agent;
    address public guardian;
    address public deskOwner;

    uint256[] public pks;
    address[] public actors;

    struct Touched {
        address seller;
        uint256 nonce;
    }

    Touched[] internal _touched;
    Touched[] internal _closed;
    bool public ghostFilledWithNonWhitelisted;
    bool public ghostEpochCountSkipped;
    bool public ghostNavWentLiveEarly;

    constructor(
        SettlementDesk desk_,
        ShareToken share_,
        NavOracle oracle_,
        MockUSDC usdc_,
        address deskOwner_,
        address compliance_,
        address agent_,
        address guardian_,
        uint256[] memory pks_
    ) {
        desk = desk_;
        share = share_;
        oracle = oracle_;
        usdc = usdc_;
        deskOwner = deskOwner_;
        compliance = compliance_;
        agent = agent_;
        guardian = guardian_;
        for (uint256 i = 0; i < pks_.length; i++) {
            pks.push(pks_[i]);
            actors.push(vm.addr(pks_[i]));
        }
    }

    // ──────────── Views for the invariants ────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return _touched.length;
    }

    function touched(uint256 i) external view returns (address, uint256) {
        return (_touched[i].seller, _touched[i].nonce);
    }

    function closedCount() external view returns (uint256) {
        return _closed.length;
    }

    function closed(uint256 i) external view returns (address, uint256) {
        return (_closed[i].seller, _closed[i].nonce);
    }

    /// @notice The order a nonce stands for.
    function orderFor(address seller, uint256 nonce) public view returns (ISettlementDesk.Order memory) {
        return ISettlementDesk.Order({
            seller: seller,
            buyer: address(0),
            shares: (nonce + 1) * 10e18,
            payment: (nonce + 1) * 9e6,
            navEpoch: 0,
            maxNavAge: nonce % 4 == 0 ? uint64(3 days) : 0,
            allowPartial: nonce % 2 == 0,
            nonce: nonce,
            deadline: block.timestamp + 3 days
        });
    }

    // ──────────── Settlement actions ────────────

    function fill(uint256 sellerSeed, uint256 buyerSeed, uint256 nonceSeed, uint256 fillSeed) external {
        uint256 si = sellerSeed % actors.length;
        address seller = actors[si];
        address buyer = actors[buyerSeed % actors.length];

        ISettlementDesk.Order memory o = orderFor(seller, bound(nonceSeed, 0, 12));
        uint256 fillShares = o.allowPartial ? bound(fillSeed, 1, o.shares) : o.shares;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[si], desk.hashOrder(o));

        bool bothListed = share.isWhitelisted(seller) && share.isWhitelisted(buyer);
        vm.prank(buyer);
        try desk.fill(o, abi.encodePacked(r, s, v), fillShares) {
            _touched.push(Touched(seller, o.nonce));
            if (!bothListed) ghostFilledWithNonWhitelisted = true;
            if (desk.nonceUsed(seller, o.nonce)) _closed.push(Touched(seller, o.nonce));
        } catch {}
    }

    function cancel(uint256 sellerSeed, uint256 nonceSeed) external {
        address seller = actors[sellerSeed % actors.length];
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = bound(nonceSeed, 0, 12);
        vm.prank(seller);
        desk.cancel(nonces);
        _touched.push(Touched(seller, nonces[0]));
        _closed.push(Touched(seller, nonces[0]));
    }

    // ──────────── NAV actions ────────────

    function proposeNav(uint256 nav, uint256 waitSeed) external {
        warp(waitSeed);
        uint256 before = oracle.epochCount();
        vm.prank(agent);
        try oracle.postNav(uint128(bound(nav, 500_000, 2_000_000)), uint64(block.timestamp)) {
            if (oracle.epochCount() != before) ghostNavWentLiveEarly = true;
        } catch {}
    }

    function proposeCorrection(uint256 nav) external {
        uint256 before = oracle.epochCount();
        vm.prank(agent);
        try oracle.correctLatest(uint128(bound(nav, 500_000, 2_000_000))) {
            if (oracle.epochCount() != before) ghostNavWentLiveEarly = true;
        } catch {}
    }

    function activateNav(uint256 waitSeed) external {
        warp(waitSeed);
        uint256 before = oracle.epochCount();
        try oracle.activatePending() {
            if (oracle.epochCount() != before + 1) ghostEpochCountSkipped = true;
        } catch {}
    }

    function vetoNav(bool byOwner) external {
        vm.prank(byOwner ? deskOwner : guardian);
        try oracle.vetoPending() {} catch {}
    }

    function withdrawNav() external {
        vm.prank(agent);
        try oracle.withdrawPending() {} catch {}
    }

    // ──────────── Compliance, admin and time ────────────

    function setWhitelistedUntil(uint256 actorSeed, uint256 untilSeed, bool remove) external {
        address a = actors[actorSeed % actors.length];
        uint64 until = remove ? 0 : uint64(block.timestamp + bound(untilSeed, 0, 10 days));
        vm.prank(compliance);
        share.setWhitelistedUntil(a, until);
    }

    function setWhitelisted(uint256 actorSeed, bool listed) external {
        vm.prank(compliance);
        share.setWhitelisted(actors[actorSeed % actors.length], listed);
    }

    function setPaused(bool pause_) external {
        vm.startPrank(deskOwner);
        if (pause_) {
            try desk.pause() {} catch {}
        } else {
            try desk.unpause() {} catch {}
        }
        vm.stopPrank();
    }

    function warp(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 8 days));
    }
}

contract SettlementDeskInvariantTest is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant SHARES_PER_ACTOR = 1_000e18;
    uint256 internal constant USDC_PER_ACTOR = 1_000_000e12;
    uint256 internal constant CHALLENGE_WINDOW = 6 hours;

    ShareToken internal share;
    NavOracle internal oracle;
    SettlementDesk internal desk;
    MockUSDC internal usdc;
    SettlementDeskHandler internal handler;

    uint256 internal initialSupply;
    uint256 internal initialUsdc;

    function setUp() public {
        vm.warp(T0);
        address compliance = address(0xC0);
        address agent = address(0xA9);
        address guardian = address(0x6A);

        usdc = new MockUSDC();
        share = ShareToken(
            address(
                new ERC1967Proxy(
                    address(new ShareToken()),
                    abi.encodeCall(
                        ShareToken.initialize, ("Halden Fund Share", "HLD", address(this), compliance, guardian)
                    )
                )
            )
        );
        oracle = NavOracle(
            address(
                new ERC1967Proxy(
                    address(new NavOracle()),
                    abi.encodeCall(NavOracle.initialize, (address(this), agent, 2000, CHALLENGE_WINDOW, guardian))
                )
            )
        );
        desk = SettlementDesk(
            address(
                new ERC1967Proxy(
                    address(new SettlementDesk(address(share), address(usdc), address(oracle))),
                    abi.encodeCall(SettlementDesk.initialize, (address(this), guardian))
                )
            )
        );

        uint256[] memory pks = new uint256[](4);
        pks[0] = 0xA1;
        pks[1] = 0xA2;
        pks[2] = 0xA3;
        pks[3] = 0xA4;

        handler = new SettlementDeskHandler(desk, share, oracle, usdc, address(this), compliance, agent, guardian, pks);

        for (uint256 i = 0; i < pks.length; i++) {
            address a = vm.addr(pks[i]);
            vm.prank(compliance);
            share.setWhitelisted(a, true);
            share.mint(a, SHARES_PER_ACTOR);
            usdc.mint(a, USDC_PER_ACTOR);
            vm.startPrank(a);
            share.approve(address(desk), type(uint256).max);
            usdc.approve(address(desk), type(uint256).max);
            vm.stopPrank();
        }
        initialSupply = share.totalSupply();
        initialUsdc = usdc.totalSupply();

        // the first NAV goes live after its challenge window
        vm.prank(agent);
        oracle.postNav(1_000_000, uint64(T0));
        vm.warp(T0 + CHALLENGE_WINDOW);
        oracle.activatePending();

        // the handler pranks as the desk owner, which is this contract
        targetContract(address(handler));
    }

    /// @notice I-1: the desk never holds shares or stablecoin.
    function invariant_deskHoldsNothing() public view {
        assertEq(share.balanceOf(address(desk)), 0, "desk holds shares");
        assertEq(usdc.balanceOf(address(desk)), 0, "desk holds stablecoin");
    }

    /// @notice I-2: no fill or cancel can create or destroy shares.
    function invariant_shareSupplyUnchanged() public view {
        assertEq(share.totalSupply(), initialSupply, "share supply changed");
    }

    /// @notice I-3: stablecoin and shares are only ever moved between actors.
    function invariant_assetsConserved() public view {
        uint256 usdcSum;
        uint256 shareSum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            usdcSum += usdc.balanceOf(a);
            shareSum += share.balanceOf(a);
        }
        assertEq(usdcSum, initialUsdc, "stablecoin not conserved");
        assertEq(shareSum, initialSupply, "shares not conserved among actors");
    }

    /// @notice I-4: an order that was fully filled or cancelled stays closed.
    function invariant_closedOrdersStayClosed() public view {
        for (uint256 i = 0; i < handler.closedCount(); i++) {
            (address seller, uint256 nonce) = handler.closed(i);
            assertTrue(desk.nonceUsed(seller, nonce), "order reopened");
        }
    }

    /// @notice I-5: every fill that went through had a whitelisted seller and buyer.
    function invariant_fillsOnlyBetweenWhitelisted() public view {
        assertFalse(handler.ghostFilledWithNonWhitelisted(), "filled with a non-whitelisted party");
    }

    /// @notice I-6: epochs only grow by one, and `asOf` never goes backwards.
    function invariant_navEpochsMonotonic() public view {
        assertFalse(handler.ghostEpochCountSkipped(), "epoch count jumped");
        uint256 n = oracle.epochCount();
        uint64 prev;
        for (uint64 e = 1; e <= n; e++) {
            (, uint64 asOf,) = oracle.navAt(e);
            assertGe(asOf, prev, "asOf went backwards");
            prev = asOf;
        }
    }

    /// @notice I-7: across partial fills a seller is never paid less than the signed price
    ///         per share, and never more than the signed total.
    function invariant_partialFillAccounting() public view {
        for (uint256 i = 0; i < handler.touchedCount(); i++) {
            (address seller, uint256 nonce) = handler.touched(i);
            ISettlementDesk.Order memory o = handler.orderFor(seller, nonce);
            (uint256 filled, uint256 paid) = desk.progress(seller, nonce);
            assertLe(filled, o.shares, "filled more than signed");
            assertLe(paid, o.payment, "paid more than signed");
            assertGe(paid * o.shares, filled * o.payment, "price fell below signed price");
        }
    }

    /// @notice I-8: a proposed NAV or correction never goes live before its challenge window ends.
    function invariant_pendingNavIsNotLive() public view {
        assertFalse(handler.ghostNavWentLiveEarly(), "NAV went live without activation");
    }
}
