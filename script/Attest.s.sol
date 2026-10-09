// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CashyAdvance} from "../src/CashyAdvance.sol";

/// @notice Frontend steps 2-3: zkTLS verification succeeds offchain, the result
///  is written onchain. The attester (demo keeper) records the creator's
///  verified AdSense final balance and the Bureau cash-out cap.
/// @dev The zkTLS proof is verified by the backend (Reclaim); only its result
///  reaches the chain, through this attest call. Run after Deploy. Env vars:
///   ADVANCE_ADDRESS, CREATOR_ADDRESS
///   FINAL_BALANCE   (cents; defaults to 8,400,000.00 IDRX, the mock page value)
///   MAX_BPS         (Bureau cap; defaults to 7000 = 70%)
///   PAYOUT_DATE     (unix seconds; defaults to Oct 21 2026 00:00 UTC)
///   ATTESTER_PRIVATE_KEY (holds ATTESTER_ROLE; defaults to anvil account 0)
contract Attest is Script {
    function run() external {
        uint256 attesterKey =
            vm.envOr("ATTESTER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        CashyAdvance advance = CashyAdvance(vm.envAddress("ADVANCE_ADDRESS"));
        address creator = vm.envAddress("CREATOR_ADDRESS");
        uint256 finalBalance = vm.envOr("FINAL_BALANCE", uint256(840_000_000));
        uint256 maxBps = vm.envOr("MAX_BPS", uint256(7000));
        uint256 payoutDate = vm.envOr("PAYOUT_DATE", uint256(1_792_540_800));

        vm.startBroadcast(attesterKey);
        advance.attest(creator, finalBalance, maxBps, payoutDate);
        vm.stopBroadcast();

        console2.log("Attested creator", creator);
        console2.log("Final balance   ", finalBalance);
        console2.log("Max bps         ", maxBps);
        console2.log("Payout date     ", payoutDate);
    }
}
