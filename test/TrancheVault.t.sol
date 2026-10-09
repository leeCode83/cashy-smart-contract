// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";

/// @notice Seam: LP deposit/withdraw + funder deploy/repay — the pool's money path.
contract TrancheVaultTest is Test {
    MockIDRX internal idrx;
    TrancheVault internal vault;
    address internal lp = makeAddr("lp");
    address internal creator = makeAddr("creator");
    uint256 internal constant CAPACITY = 200_000_000_00; // 200,000,000.00 IDRX

    function setUp() public {
        idrx = new MockIDRX(0);
        vault = new TrancheVault(IERC20(address(idrx)), "Cashy Senior", "csIDRX", CAPACITY);
        vault.grantRole(vault.FUNDER_ROLE(), address(this));
        idrx.mint(lp, 10_000_000_00);
        vm.prank(lp);
        idrx.approve(address(vault), type(uint256).max);
    }

    function test_FirstDepositMintsOneToOne() public {
        vm.prank(lp);
        uint256 shares = vault.deposit(5_000_000_00, lp);
        assertEq(shares, 5_000_000_00);
        assertEq(vault.balanceOf(lp), 5_000_000_00);
    }

    /// UI: "Capacity left" — deposit beyond it must fail loudly.
    function test_DepositOverCapacityReverts() public {
        idrx.mint(lp, CAPACITY);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626.ERC4626ExceededMaxDeposit.selector, lp, CAPACITY + 1, CAPACITY
            )
        );
        vault.deposit(CAPACITY + 1, lp);
    }

    function test_WithdrawReturnsAssets() public {
        vm.startPrank(lp);
        vault.deposit(5_000_000_00, lp);
        vault.redeem(vault.balanceOf(lp), lp, lp);
        vm.stopPrank();
        assertEq(idrx.balanceOf(lp), 10_000_000_00);
        assertEq(vault.totalAssets(), 0);
    }

    /// Advance outflow must not change LP accounting: balance drops, deployed rises.
    function test_DeployMovesAssetsOutKeepingTotalAssets() public {
        vm.prank(lp);
        vault.deposit(5_000_000_00, lp);
        vault.deploy(creator, 5_000_000_00);
        assertEq(idrx.balanceOf(creator), 5_000_000_00);
        assertEq(vault.deployed(), 5_000_000_00);
        assertEq(vault.totalAssets(), 5_000_000_00);
    }

    /// Repay inflow + settleRepaid keeps accounting exact.
    function test_SettleRepaidRestoresLiquidity() public {
        vm.prank(lp);
        vault.deposit(5_000_000_00, lp);
        vault.deploy(creator, 5_000_000_00);
        idrx.mint(address(vault), 5_000_000_00); // principal flows back via sweep
        vault.settleRepaid(5_000_000_00);
        assertEq(vault.deployed(), 0);
        assertEq(vault.totalAssets(), 5_000_000_00);
        assertEq(idrx.balanceOf(address(vault)), 5_000_000_00);
    }

    function test_DeployByNonFunderReverts() public {
        vm.prank(lp);
        vault.deposit(1_000_000_00, lp);
        vm.prank(lp);
        vm.expectRevert();
        vault.deploy(creator, 1_000_000_00);
    }

    function test_SettleRepaidByNonFunderReverts() public {
        vm.prank(lp);
        vm.expectRevert();
        vault.settleRepaid(1);
    }

    /// Yield mechanism: assets donated straight into the vault raise share price,
    /// so the same share redeems for more — that is the LP yield in this design.
    /// 1-unit tolerance = OZ ERC-4626 preview rounding (totalAssets+1 / supply+1).
    function test_DonationRaisesSharePrice() public {
        vm.prank(lp);
        vault.deposit(10_000_000_00, lp);
        idrx.mint(address(vault), 1_000_000_00); // 10% yield arrives as a transfer
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp)), 11_000_000_00, 1);
    }
}
