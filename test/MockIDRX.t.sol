// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockIDRX} from "../src/MockIDRX.sol";

/// @notice Behavior tests for the demo IDRX stablecoin (money path fixture).
contract MockIDRXTest is Test {
    MockIDRX internal idrx;
    address internal alice = makeAddr("alice");

    function setUp() public {
        idrx = new MockIDRX(0);
    }

    /// UI brief: amounts render with 2 decimals — token must match (1 unit = 1 cent).
    function test_DecimalsIsTwo() public view {
        assertEq(idrx.decimals(), 2);
    }

    /// 1,000,000.00 IDRX = 100,000,000 cents.
    function test_MintAddsBalance() public {
        idrx.mint(alice, 100_000_000);
        assertEq(idrx.balanceOf(alice), 100_000_000);
    }

    function test_TransferMovesBalance() public {
        idrx.mint(alice, 100);
        vm.prank(alice);
        assertTrue(idrx.transfer(makeAddr("bob"), 100));
        assertEq(idrx.balanceOf(makeAddr("bob")), 100);
        assertEq(idrx.balanceOf(alice), 0);
    }

    /// Admin-gated mint keeps test accounting and invariants exact.
    function test_NonMinterCannotMint() public {
        vm.prank(alice);
        vm.expectRevert();
        idrx.mint(alice, 100);
    }
}
