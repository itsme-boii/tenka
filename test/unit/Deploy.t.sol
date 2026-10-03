// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {ShareToken} from "../../src/ShareToken.sol";
import {NavOracle} from "../../src/NavOracle.sol";
import {SettlementDesk} from "../../src/SettlementDesk.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice The deploy script produces a correctly wired, correctly owned stack.
contract DeployTest is Test {
    function test_deploy_wiresEverything() public {
        address owner = address(0x01);
        address compliance = address(0x02);
        address agent = address(0x03);
        address guardian = address(0x04);
        MockUSDC usdc = new MockUSDC();

        Deploy.Deployed memory d = new Deploy().deploy(owner, compliance, agent, guardian, address(usdc));

        ShareToken share = ShareToken(d.shareToken);
        NavOracle oracle = NavOracle(d.navOracle);
        SettlementDesk desk = SettlementDesk(d.settlementDesk);

        assertEq(share.owner(), owner);
        assertEq(share.complianceOfficer(), compliance);
        assertEq(oracle.owner(), owner);
        assertEq(oracle.valuationAgent(), agent);
        assertEq(oracle.maxChangeBps(), 2000);
        assertEq(desk.owner(), owner);
        assertEq(address(desk.shareToken()), d.shareToken);
        assertEq(address(desk.stablecoin()), address(usdc));
        assertEq(address(desk.navOracle()), d.navOracle);
    }

    function test_deploy_implementationsAreLocked() public {
        MockUSDC usdc = new MockUSDC();
        Deploy.Deployed memory d = new Deploy().deploy(address(1), address(2), address(3), address(4), address(usdc));
        vm.expectRevert();
        ShareToken(d.shareTokenImpl).initialize("x", "x", address(1), address(2), address(4));
        vm.expectRevert();
        NavOracle(d.navOracleImpl).initialize(address(1), address(3), 2000, 0, address(4));
        vm.expectRevert();
        SettlementDesk(d.settlementDeskImpl).initialize(address(1), address(4));
    }

    function test_deploy_setsGuardianEverywhere() public {
        MockUSDC usdc = new MockUSDC();
        Deploy.Deployed memory d = new Deploy().deploy(address(1), address(2), address(3), address(4), address(usdc));
        assertEq(ShareToken(d.shareToken).guardian(), address(4));
        assertEq(NavOracle(d.navOracle).guardian(), address(4));
        assertEq(SettlementDesk(d.settlementDesk).guardian(), address(4));
        assertEq(NavOracle(d.navOracle).challengeWindow(), 6 hours);
    }

    function test_productionConfig_acceptsContractOwnerAndSeparateGuardian() public {
        Deploy script = new Deploy();
        script.checkProductionConfig(address(new MockUSDC()), address(0x6A)); // any contract stands in for a Safe
    }

    function test_RevertWhen_productionOwnerIsAnEoa() public {
        Deploy script = new Deploy();
        vm.expectRevert(Deploy.OwnerMustBeContract.selector);
        script.checkProductionConfig(address(0x01), address(0x6A));
    }

    function test_RevertWhen_productionGuardianMissingOrSameAsOwner() public {
        Deploy script = new Deploy();
        address safe = address(new MockUSDC());
        vm.expectRevert(Deploy.GuardianMustDifferFromOwner.selector);
        script.checkProductionConfig(safe, address(0));
        vm.expectRevert(Deploy.GuardianMustDifferFromOwner.selector);
        script.checkProductionConfig(safe, safe);
    }
}
