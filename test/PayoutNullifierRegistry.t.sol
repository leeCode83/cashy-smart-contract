// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {PayoutNullifierRegistry} from "../src/PayoutNullifierRegistry.sol";

/// @notice Seam: claim / isClaimed — the shared anti-double-funding truth all lenders read.
contract PayoutNullifierRegistryTest is Test {
    PayoutNullifierRegistry internal registry;
    address internal funder = makeAddr("funder");
    bytes32 internal payoutId = keccak256("payout-1");

    event PayoutClaimed(bytes32 indexed payoutId, address indexed creator);

    function setUp() public {
        registry = new PayoutNullifierRegistry(funder);
    }

    function test_InitialUnclaimed() public view {
        assertFalse(registry.isClaimed(payoutId));
    }

    function test_ClaimMarksPayoutAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit PayoutClaimed(payoutId, funder);
        vm.prank(funder);
        registry.claim(payoutId, funder);
        assertTrue(registry.isClaimed(payoutId));
    }

    /// Core product promise: one payout can never be funded twice, by anyone.
    function test_DoubleClaimReverts() public {
        vm.prank(funder);
        registry.claim(payoutId, funder);
        vm.prank(funder);
        vm.expectRevert(PayoutNullifierRegistry.AlreadyClaimed.selector);
        registry.claim(payoutId, funder);
    }

    /// A rival lender must not poison the registry by claiming arbitrary payouts.
    function test_NonFunderClaimReverts() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        registry.claim(payoutId, funder);
    }
}
