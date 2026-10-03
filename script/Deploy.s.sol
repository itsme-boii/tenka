// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ShareToken} from "../src/ShareToken.sol";
import {NavOracle} from "../src/NavOracle.sol";
import {SettlementDesk} from "../src/SettlementDesk.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @title Deploy — deploys the full Halden stack behind ERC1967 proxies
/// @notice Deploys ShareToken, NavOracle and SettlementDesk (implementation plus proxy for
///         each) and writes every address to `deployments/<chainId>.json`, which is the
///         single source of truth for addresses.
///
/// @dev Usage (the key comes from a keystore, never from `.env`):
///     cast wallet import halden-deployer --interactive
///     forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_SEPOLIA_RPC_URL \
///         --account halden-deployer --broadcast --verify
///
///   Env: OWNER, COMPLIANCE_OFFICER, VALUATION_AGENT, GUARDIAN, and optionally STABLECOIN.
///   If STABLECOIN is unset, a MockUSDC is deployed. That is allowed on testnets only.
///
///   On any chain other than a testnet the script refuses to run unless OWNER is a
///   contract (a multisig) and GUARDIAN is a different, non-zero address. The guardian
///   can veto a pending NAV and cancel a queued upgrade, so it should be a separate key.
contract Deploy is Script {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant MAX_CHANGE_BPS = 2000;
    uint256 internal constant CHALLENGE_WINDOW = 6 hours;

    struct Deployed {
        address stablecoin;
        address shareToken;
        address shareTokenImpl;
        address navOracle;
        address navOracleImpl;
        address settlementDesk;
        address settlementDeskImpl;
    }

    error MockStablecoinOnlyOnTestnet();
    error OwnerMustBeContract();
    error GuardianMustDifferFromOwner();

    function run() external returns (Deployed memory d) {
        address owner = vm.envAddress("OWNER");
        address compliance = vm.envAddress("COMPLIANCE_OFFICER");
        address agent = vm.envAddress("VALUATION_AGENT");
        address guardian = vm.envAddress("GUARDIAN");
        address stablecoin = vm.envOr("STABLECOIN", address(0));

        bool testnet = block.chainid == ANVIL || block.chainid == BASE_SEPOLIA;
        if (!testnet) checkProductionConfig(owner, guardian);
        if (stablecoin == address(0) && !testnet) revert MockStablecoinOnlyOnTestnet();

        vm.startBroadcast();
        if (stablecoin == address(0)) stablecoin = address(new MockUSDC());
        d = deploy(owner, compliance, agent, guardian, stablecoin);
        vm.stopBroadcast();

        _write(d);
        console.log("ShareToken      ", d.shareToken);
        console.log("NavOracle       ", d.navOracle);
        console.log("SettlementDesk  ", d.settlementDesk);
    }

    /// @notice The rules for a deployment that is not a testnet demo.
    function checkProductionConfig(address owner, address guardian) public view {
        if (owner.code.length == 0) revert OwnerMustBeContract();
        if (guardian == address(0) || guardian == owner) revert GuardianMustDifferFromOwner();
    }

    /// @notice Deployment logic, split from `run` so tests can call it without broadcasting.
    function deploy(address owner, address compliance, address agent, address guardian, address stablecoin)
        public
        returns (Deployed memory d)
    {
        d.stablecoin = stablecoin;

        d.shareTokenImpl = address(new ShareToken());
        d.shareToken = address(
            new ERC1967Proxy(
                d.shareTokenImpl,
                abi.encodeCall(ShareToken.initialize, ("Halden Fund Share", "HLD", owner, compliance, guardian))
            )
        );

        d.navOracleImpl = address(new NavOracle());
        d.navOracle = address(
            new ERC1967Proxy(
                d.navOracleImpl,
                abi.encodeCall(NavOracle.initialize, (owner, agent, MAX_CHANGE_BPS, CHALLENGE_WINDOW, guardian))
            )
        );

        d.settlementDeskImpl = address(new SettlementDesk(d.shareToken, stablecoin, d.navOracle));
        d.settlementDesk = address(
            new ERC1967Proxy(d.settlementDeskImpl, abi.encodeCall(SettlementDesk.initialize, (owner, guardian)))
        );
    }

    function _write(Deployed memory d) internal {
        string memory k = "deployment";
        vm.serializeAddress(k, "stablecoin", d.stablecoin);
        vm.serializeAddress(k, "shareToken", d.shareToken);
        vm.serializeAddress(k, "shareTokenImpl", d.shareTokenImpl);
        vm.serializeAddress(k, "navOracle", d.navOracle);
        vm.serializeAddress(k, "navOracleImpl", d.navOracleImpl);
        vm.serializeAddress(k, "settlementDesk", d.settlementDesk);
        string memory json = vm.serializeAddress(k, "settlementDeskImpl", d.settlementDeskImpl);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}
