// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";

interface IBlacklistableUsdc is IERC20 {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice The desk against the real USDC on Base: a proxy token with a blacklist, which
///         the mocks cannot reproduce. Skipped unless `BASE_RPC_URL` is set, so a plain
///         `forge test` stays offline.
contract UsdcForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base mainnet

    address internal owner = address(this);
    address internal compliance = address(0xC0);
    address internal agent = address(0xA9);
    address internal guardian = address(0x6A);

    uint256 internal sellerPk = 0x5E11E4;
    uint256 internal buyerPk = 0xB07E4;
    address internal seller;
    address internal buyer;

    ShareToken internal share;
    NavOracle internal oracle;
    SettlementDesk internal desk;
    IBlacklistableUsdc internal usdc = IBlacklistableUsdc(USDC);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        seller = vm.addr(sellerPk);
        buyer = vm.addr(buyerPk);

        Deploy.Deployed memory d = new Deploy().deploy(owner, compliance, agent, guardian, USDC);
        share = ShareToken(d.shareToken);
        oracle = NavOracle(d.navOracle);
        desk = SettlementDesk(d.settlementDesk);

        vm.startPrank(compliance);
        share.setWhitelisted(seller, true);
        share.setWhitelisted(buyer, true);
        vm.stopPrank();
        share.mint(seller, 1_000e18);

        deal(USDC, buyer, 1_000_000e6);
        vm.prank(seller);
        share.approve(address(desk), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(desk), type(uint256).max);

        // the demo's challenge window is 6 hours, so the first NAV goes live after it
        vm.prank(agent);
        oracle.postNav(1_000_000, uint64(block.timestamp));
        vm.warp(block.timestamp + 6 hours);
        oracle.activatePending();
    }

    function _order(uint256 shares, uint256 payment, bool allowPartial_)
        internal
        view
        returns (ISettlementDesk.Order memory)
    {
        return ISettlementDesk.Order({
            seller: seller,
            buyer: address(0),
            shares: shares,
            payment: payment,
            navEpoch: 0,
            maxNavAge: 0,
            allowPartial: allowPartial_,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(ISettlementDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, desk.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    function test_fork_fill_withRealUsdc() public {
        ISettlementDesk.Order memory o = _order(100e18, 80e6, false); // a 20% discount
        bytes memory sig = _sign(o);

        vm.prank(buyer);
        desk.fill(o, sig, o.shares);

        assertEq(usdc.balanceOf(seller), 80e6);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6 - 80e6);
        assertEq(share.balanceOf(buyer), 100e18);
        assertEq(usdc.balanceOf(address(desk)), 0);
        assertEq(share.balanceOf(address(desk)), 0);
    }

    function test_fork_partialFills_withRealUsdc() public {
        ISettlementDesk.Order memory o = _order(3e18, 100, true); // 100 base units does not divide by 3
        bytes memory sig = _sign(o);

        vm.startPrank(buyer);
        desk.fill(o, sig, 1e18);
        desk.fill(o, sig, 1e18);
        desk.fill(o, sig, 1e18);
        vm.stopPrank();

        assertEq(usdc.balanceOf(seller), 100); // 34 + 34 + 32
        assertEq(share.balanceOf(buyer), 3e18);
    }

    function test_fork_RevertWhen_sellerBlacklistedByCircle_andNothingMoves() public {
        vm.prank(usdc.blacklister());
        usdc.blacklist(seller);
        assertTrue(usdc.isBlacklisted(seller));

        ISettlementDesk.Order memory o = _order(100e18, 80e6, false);
        bytes memory sig = _sign(o);
        vm.prank(buyer);
        vm.expectRevert(); // USDC refuses to pay a blacklisted account
        desk.fill(o, sig, o.shares);

        assertEq(usdc.balanceOf(buyer), 1_000_000e6); // the buyer keeps the stablecoin
        assertEq(share.balanceOf(seller), 1_000e18); // and the seller keeps the shares
        assertFalse(desk.nonceUsed(seller, 1));
    }

    function test_fork_RevertWhen_buyerBlacklistedByCircle_andNothingMoves() public {
        vm.prank(usdc.blacklister());
        usdc.blacklist(buyer);

        ISettlementDesk.Order memory o = _order(100e18, 80e6, false);
        bytes memory sig = _sign(o);
        vm.prank(buyer);
        vm.expectRevert();
        desk.fill(o, sig, o.shares);

        assertEq(share.balanceOf(buyer), 0);
        assertEq(share.balanceOf(seller), 1_000e18);
    }

    function test_fork_usdcIsNotFeeOnTransfer() public {
        // the desk's balance-delta check relies on this staying true
        address a = address(0xAAA);
        deal(USDC, a, 1_000e6);
        vm.prank(a);
        usdc.transfer(address(0xBBB), 1_000e6);
        assertEq(usdc.balanceOf(address(0xBBB)), 1_000e6);
    }
}
