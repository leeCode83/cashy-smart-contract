// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";

/// @notice Frontend step 1: an LP funds a tranche vault.
/// @dev Mirrors the UI "deposit to vault" action for one liquidity provider that
///  is NOT the deployer. The deployer (MockIDRX minter) tops the LP up first so
///  the demo needs no faucet UI, then the LP approves and deposits itself.
///  Run on Anvil after Deploy. Env vars:
///   IDRX_ADDRESS, VAULT_ADDRESS  (which tranche to fund)
///   LP_PRIVATE_KEY               (the LP wallet; defaults to anvil account 1)
///   DEPOSIT_AMOUNT               (cents; defaults to 50,000,000.00 IDRX)
///   MINTER_PRIVATE_KEY           (deployer/minter; defaults to anvil account 0)
contract LpDeposit is Script {
    function run() external {
        uint256 lpKey =
            vm.envOr("LP_PRIVATE_KEY", uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d));
        uint256 minterKey =
            vm.envOr("MINTER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        MockIDRX idrx = MockIDRX(vm.envAddress("IDRX_ADDRESS"));
        TrancheVault vault = TrancheVault(vm.envAddress("VAULT_ADDRESS"));
        uint256 amount = vm.envOr("DEPOSIT_AMOUNT", uint256(50_000_000_00));

        address lp = vm.addr(lpKey);

        // Deployer funds the LP wallet so the demo needs no separate faucet step.
        vm.startBroadcast(minterKey);
        idrx.mint(lp, amount);
        vm.stopBroadcast();

        // The LP itself approves and deposits — exactly what the UI triggers.
        vm.startBroadcast(lpKey);
        idrx.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, lp);
        vm.stopBroadcast();

        console2.log("LP            ", lp);
        console2.log("Vault         ", address(vault));
        console2.log("Deposited     ", amount);
        console2.log("Shares minted ", shares);
    }
}
