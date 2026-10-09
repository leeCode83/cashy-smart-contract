// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {CashyAdvance} from "../src/CashyAdvance.sol";

/// @notice Demo payday: simulates Google's payout landing on the 21st, then the
///  keeper settles the advance — the whole auto-repay story in two steps.
/// @dev Run on Anvil after Deploy + a creator advance. Env vars:
///   ADVANCE_ADDRESS, IDRX_ADDRESS, CREATOR_ADDRESS, ADVANCE_ID
///   KEEPER_PRIVATE_KEY (defaults to anvil account 0 = deployer).
contract DemoKeeper is Script {
    function run() external {
        uint256 keeperKey =
            vm.envOr("KEEPER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        CashyAdvance advance = CashyAdvance(vm.envAddress("ADVANCE_ADDRESS"));
        MockIDRX idrx = MockIDRX(vm.envAddress("IDRX_ADDRESS"));
        address creator = vm.envAddress("CREATOR_ADDRESS");
        uint256 id = vm.envOr("ADVANCE_ID", uint256(1));

        (, , , uint256 principal, uint256 fee, ) = advance.advances(id);
        uint256 repay = principal + fee;

        vm.startBroadcast(keeperKey);
        // Google's payout lands in the creator's payout account on the 21st.
        idrx.mint(creator, repay);
        // Open-finance rail (demo: keeper) collects advance + fee automatically.
        advance.settle(id);
        vm.stopBroadcast();

        console2.log("Payout simulated", repay);
        console2.log("Advance settled", id);
        console2.log("On-time repays", advance.onTimeRepays(creator));
    }
}
