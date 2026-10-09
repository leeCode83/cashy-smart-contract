// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";
import {WaterfallSweep} from "../src/WaterfallSweep.sol";
import {PayoutNullifierRegistry} from "../src/PayoutNullifierRegistry.sol";
import {CashyAdvance} from "../src/CashyAdvance.sol";

/// @notice Full wiring for the Cashy demo pool. Simulation only here — running
///  with --broadcast is a deliberate deploy decision.
/// @dev Capacity numbers follow the UI brief mock scale: Senior 200M, Junior
///  50M, Reserve 100M IDRX (cents internally).
contract Deploy is Script {
    function run()
        external
        returns (
            MockIDRX idrx,
            TrancheVault senior,
            TrancheVault junior,
            TrancheVault reserve,
            PayoutNullifierRegistry registry,
            WaterfallSweep sweep,
            CashyAdvance advance
        )
    {
        uint256 keeperKey = vm.envOr("KEEPER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address keeper = vm.addr(keeperKey);
        address attester = keeper; // demo: one operator plays bureau and keeper

        vm.startBroadcast();
        idrx = new MockIDRX(1_000_000_000_00);

        senior = new TrancheVault(IERC20(address(idrx)), "Cashy Senior", "csIDRX", 200_000_000_00);
        junior = new TrancheVault(IERC20(address(idrx)), "Cashy Junior", "cjIDRX", 50_000_000_00);
        reserve = new TrancheVault(IERC20(address(idrx)), "Cashy Reserve", "crIDRX", 100_000_000_00);

        registry = new PayoutNullifierRegistry(address(0));
        advance = new CashyAdvance(IERC20(address(idrx)), senior, registry, 2 days);
        registry.setFunder(address(advance));
        sweep = new WaterfallSweep(address(advance), senior, junior, reserve, 7000, 2000);
        advance.setSweep(sweep);

        // Funding and settlement powers.
        senior.grantRole(senior.FUNDER_ROLE(), address(advance));
        senior.grantRole(senior.FUNDER_ROLE(), address(sweep));
        advance.grantRole(advance.ATTESTER_ROLE(), attester);
        advance.grantRole(advance.SETTLER_ROLE(), keeper);

        // Demo LP fills the tranches so advances have liquidity.
        idrx.approve(address(senior), type(uint256).max);
        idrx.approve(address(junior), type(uint256).max);
        idrx.approve(address(reserve), type(uint256).max);
        senior.deposit(150_000_000_00, msg.sender);
        junior.deposit(30_000_000_00, msg.sender);
        reserve.deposit(50_000_000_00, msg.sender);
        vm.stopBroadcast();

        console2.log("MockIDRX      ", address(idrx));
        console2.log("SeniorVault   ", address(senior));
        console2.log("JuniorVault   ", address(junior));
        console2.log("ReserveVault  ", address(reserve));
        console2.log("Registry      ", address(registry));
        console2.log("Sweep         ", address(sweep));
        console2.log("Advance       ", address(advance));
        console2.log("Keeper/Attest ", keeper);
    }
}
