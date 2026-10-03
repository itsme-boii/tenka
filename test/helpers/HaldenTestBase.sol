// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {ISettlementDesk} from "../../src/interfaces/ISettlementDesk.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Deploys the full stack behind proxies and gives tests an order/sign toolkit.
abstract contract HaldenTestBase is Test {
    uint256 internal constant T0 = 1_700_000_000;
    uint128 internal constant NAV = 1_000_000; // 1.00 USDC per share

    address internal owner;
    address internal compliance = address(0xC0);
    address internal agent = address(0xA9);
    address internal guardian = address(0x6A);

    uint256 internal sellerPk = 0x5E11E4;
    uint256 internal buyerPk = 0xB07E4;
    address internal seller;
    address internal buyer;
    address internal outsider = address(0xBAD);

    MockUSDC internal usdc;
    ShareToken internal share;
    NavOracle internal oracle;
    SettlementDesk internal desk;

    function setUp() public virtual {
        vm.warp(T0);
        owner = address(this);
        seller = vm.addr(sellerPk);
        buyer = vm.addr(buyerPk);

        usdc = new MockUSDC();
        share = ShareToken(
            _proxy(
                address(new ShareToken()),
                abi.encodeCall(ShareToken.initialize, ("Halden Fund Share", "HLD", owner, compliance, guardian))
            )
        );
        oracle = NavOracle(
            _proxy(address(new NavOracle()), abi.encodeCall(NavOracle.initialize, (owner, agent, 2000, 0, guardian)))
        );
        desk = _deployDesk(address(share), address(usdc), address(oracle));

        vm.startPrank(compliance);
        share.setWhitelisted(seller, true);
        share.setWhitelisted(buyer, true);
        vm.stopPrank();

        share.mint(seller, 1_000e18);
        usdc.mint(buyer, 1_000_000e6);

        vm.prank(seller);
        share.approve(address(desk), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(desk), type(uint256).max);

        _postNav(NAV);
    }

    // ──────────── Deploy helpers ────────────

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function _deployDesk(address share_, address stable_, address oracle_) internal returns (SettlementDesk) {
        return SettlementDesk(
            _proxy(
                address(new SettlementDesk(share_, stable_, oracle_)),
                abi.encodeCall(SettlementDesk.initialize, (owner, guardian))
            )
        );
    }

    function _postNav(uint128 nav) internal {
        vm.prank(agent);
        oracle.postNav(nav, uint64(block.timestamp));
    }

    // ──────────── Order helpers ────────────

    function _order(uint256 shares, uint256 payment) internal view returns (ISettlementDesk.Order memory o) {
        o = ISettlementDesk.Order({
            seller: seller,
            buyer: address(0),
            shares: shares,
            payment: payment,
            navEpoch: 0,
            maxNavAge: 0,
            allowPartial: false,
            nonce: 1,
            deadline: block.timestamp + 1 days
        });
    }

    function _sign(uint256 pk, SettlementDesk d, ISettlementDesk.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d.hashOrder(o));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Fills the whole order as the buyer.
    function _fill(ISettlementDesk.Order memory o) internal {
        _fillShares(o, o.shares);
    }

    function _fillShares(ISettlementDesk.Order memory o, uint256 fillShares) internal {
        bytes memory sig = _sign(sellerPk, desk, o);
        vm.prank(buyer);
        desk.fill(o, sig, fillShares);
    }
}
