// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";
import {WaterfallSweep} from "../src/WaterfallSweep.sol";

/// @notice Seam: distribute(principal, fee) — repay money splits across tranches.
contract WaterfallSweepTest is Test {
    MockIDRX internal idrx;
    TrancheVault internal senior;
    TrancheVault internal junior;
    TrancheVault internal reserve;
    WaterfallSweep internal sweep;
    address internal lp = makeAddr("lp");
    address internal settler = makeAddr("settler");

    // UI brief fee example: advance 5,000,000.00, fee 2.5% = 125,000.00.
    uint256 internal constant PRINCIPAL = 500_000_000;
    uint256 internal constant FEE = 12_500_000;

    function setUp() public {
        idrx = new MockIDRX(0);
        senior = new TrancheVault(IERC20(address(idrx)), "Cashy Senior", "csIDRX", type(uint256).max);
        junior = new TrancheVault(IERC20(address(idrx)), "Cashy Junior", "cjIDRX", type(uint256).max);
        reserve = new TrancheVault(IERC20(address(idrx)), "Cashy Reserve", "crIDRX", type(uint256).max);
        sweep = new WaterfallSweep(
            settler, senior, junior, reserve, 7000, 2000
        );
        // Tranches must hand deploy/settle power to the sweep (it returns principal).
        senior.grantRole(senior.FUNDER_ROLE(), address(sweep));
        // Seed LP deposits so tranche accounting is observable.
        idrx.mint(lp, 100_000_000_00);
        vm.startPrank(lp);
        idrx.approve(address(senior), type(uint256).max);
        idrx.approve(address(junior), type(uint256).max);
        idrx.approve(address(reserve), type(uint256).max);
        senior.deposit(10_000_000_00, lp);
        junior.deposit(10_000_000_00, lp);
        reserve.deposit(10_000_000_00, lp);
        vm.stopPrank();
        // Simulate a settled repayment arriving at the sweep.
        idrx.mint(address(sweep), PRINCIPAL + FEE);
    }

    function test_PrincipalGoesEntirelyToSenior() public {
        vm.prank(settler);
        sweep.distribute(PRINCIPAL, FEE);
        // Senior: initial deposit + 100% principal + its 70% fee cut.
        assertEq(idrx.balanceOf(address(senior)), 10_000_000_00 + PRINCIPAL + 8_750_000);
    }

    /// Default 70/20/10: fee splits exactly; remainder (rounding dust) to Reserve.
    function test_FeeSplitsByRatio() public {
        vm.prank(settler);
        sweep.distribute(PRINCIPAL, FEE);
        assertEq(idrx.balanceOf(address(senior)) - 10_000_000_00 - PRINCIPAL, 8_750_000);
        assertEq(idrx.balanceOf(address(junior)) - 10_000_000_00, 2_500_000);
        assertEq(idrx.balanceOf(address(reserve)) - 10_000_000_00, 1_250_000);
    }

    /// Rounding dust must never be lost: reserve takes the remainder.
    function test_OddFeeDustGoesToReserve() public {
        uint256 oddFee = 1_234_567;
        idrx.mint(address(sweep), oddFee);
        vm.prank(settler);
        sweep.distribute(0, oddFee);
        uint256 seniorCut = (oddFee * 7000) / 10_000; // 864,196
        uint256 juniorCut = (oddFee * 2000) / 10_000; // 246,913
        assertEq(idrx.balanceOf(address(senior)) - 10_000_000_00, seniorCut);
        assertEq(idrx.balanceOf(address(junior)) - 10_000_000_00, juniorCut);
        assertEq(idrx.balanceOf(address(reserve)) - 10_000_000_00, oddFee - seniorCut - juniorCut);
    }

    function test_NonSettlerReverts() public {
        vm.prank(lp);
        vm.expectRevert();
        sweep.distribute(PRINCIPAL, FEE);
    }

    /// Ratios beyond 10,000 bps would promise more fee than exists.
    function test_BadRatioConstructionReverts() public {
        vm.expectRevert();
        new WaterfallSweep(settler, senior, junior, reserve, 8000, 3000);
    }

    function test_SetRatiosAppliesToNextDistributions() public {
        vm.prank(settler);
        sweep.setRatios(5000, 5000);
        vm.prank(settler);
        sweep.distribute(PRINCIPAL, FEE);
        assertEq(idrx.balanceOf(address(senior)) - 10_000_000_00 - PRINCIPAL, 6_250_000);
        assertEq(idrx.balanceOf(address(junior)) - 10_000_000_00, 6_250_000);
        assertEq(idrx.balanceOf(address(reserve)) - 10_000_000_00, 0);
    }
}
