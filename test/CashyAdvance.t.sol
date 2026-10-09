// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";
import {WaterfallSweep} from "../src/WaterfallSweep.sol";
import {PayoutNullifierRegistry} from "../src/PayoutNullifierRegistry.sol";
import {CashyAdvance} from "../src/CashyAdvance.sol";

/// @notice Seam: attest → requestAdvance → settle — the whole creator money path.
/// @dev Numbers follow the UI brief example: 5,000,000.00 advance, 2.5% fee
///  = 125,000.00, repay 5,125,000.00 on the 21st.
contract CashyAdvanceTest is Test {
    MockIDRX internal idrx;
    TrancheVault internal senior;
    TrancheVault internal junior;
    TrancheVault internal reserve;
    WaterfallSweep internal sweep;
    PayoutNullifierRegistry internal registry;
    CashyAdvance internal advance;

    address internal creator = makeAddr("creator");
    address internal keeper = makeAddr("keeper");
    address internal attester = makeAddr("attester");
    bytes32 internal payoutId = keccak256("adsense-final-2026-10");

    // Oct 21, 2026 00:00 UTC — Google payout day.
    uint256 internal constant PAYOUT_DATE = 1_792_540_800;
    uint256 internal constant FINAL_BALANCE = 840_000_000; // 8,400,000.00
    uint256 internal constant AMOUNT = 500_000_000; // 5,000,000.00
    uint256 internal constant FEE = 12_500_000; // 125,000.00
    uint256 internal constant REPAY = 512_500_000; // 5,125,000.00

    event AdvanceCreated(uint256 indexed id, address indexed creator, uint256 principal, uint256 fee);
    event RepaidOnTime(address indexed creator, uint256 indexed id);

    function setUp() public {
        idrx = new MockIDRX(0);
        senior = new TrancheVault(IERC20(address(idrx)), "Cashy Senior", "csIDRX", type(uint256).max);
        junior = new TrancheVault(IERC20(address(idrx)), "Cashy Junior", "cjIDRX", type(uint256).max);
        reserve = new TrancheVault(IERC20(address(idrx)), "Cashy Reserve", "crIDRX", type(uint256).max);
        // Registry first with no funder; advance wired in right after.
        registry = new PayoutNullifierRegistry(address(0));
        advance = new CashyAdvance(IERC20(address(idrx)), senior, registry, 2 days);
        registry.setFunder(address(advance));
        sweep = new WaterfallSweep(address(advance), senior, junior, reserve, 7000, 2000);
        advance.setSweep(sweep);
        senior.grantRole(senior.FUNDER_ROLE(), address(advance));
        // Sweep moves principal into senior during distribute.
        senior.grantRole(senior.FUNDER_ROLE(), address(sweep));
        advance.grantRole(advance.ATTESTER_ROLE(), attester);
        advance.grantRole(advance.SETTLER_ROLE(), keeper);
        _seedPool();
        _attest();
    }

    function _seedPool() internal {
        address lp = makeAddr("lp");
        idrx.mint(lp, 100_000_000_00);
        vm.startPrank(lp);
        idrx.approve(address(senior), type(uint256).max);
        idrx.approve(address(junior), type(uint256).max);
        idrx.approve(address(reserve), type(uint256).max);
        senior.deposit(50_000_000_00, lp);
        junior.deposit(25_000_000_00, lp);
        reserve.deposit(25_000_000_00, lp);
        vm.stopPrank();
    }

    function _attest() internal {
        vm.prank(attester);
        advance.attest(creator, FINAL_BALANCE, 7000, PAYOUT_DATE);
    }

    function _creatorApprovesAndRequests() internal returns (uint256 id) {
        vm.startPrank(creator);
        idrx.approve(address(advance), type(uint256).max);
        id = advance.requestAdvance(AMOUNT, payoutId);
        vm.stopPrank();
    }

    function test_FeeMathMatchesUiExample() public {
        idrx.mint(creator, 1);
        vm.prank(creator);
        (uint256 fee, uint256 repay) = advance.previewFee(AMOUNT);
        assertEq(fee, FEE);
        assertEq(repay, REPAY);
    }

    function test_HappyPathFundsCreatorFromSenior() public {
        uint256 id = _creatorApprovesAndRequests();
        assertEq(idrx.balanceOf(creator), AMOUNT);
        (address advCreator, , , uint256 principal, uint256 fee, ) = advance.advances(id);
        assertEq(advCreator, creator);
        assertEq(principal, AMOUNT);
        assertEq(fee, FEE);
        assertTrue(registry.isClaimed(payoutId));
        assertTrue(advance.activeAdvanceId(creator) != 0);
    }

    function test_AdvanceMarksNullifierClaimed() public {
        _creatorApprovesAndRequests();
        assertTrue(registry.isClaimed(payoutId));
    }

    function test_AdvanceWithoutAttestationReverts() public {
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert();
        advance.requestAdvance(AMOUNT, keccak256("other"));
    }

    function test_AdvanceOverBureauLimitReverts() public {
        vm.startPrank(creator);
        idrx.approve(address(advance), type(uint256).max);
        vm.expectRevert();
        advance.requestAdvance(FINAL_BALANCE, payoutId); // 100% > 70% limit
        vm.stopPrank();
    }

    function test_AdvanceBelowMinimumReverts() public {
        vm.prank(creator);
        vm.expectRevert();
        advance.requestAdvance(1, payoutId);
    }

    /// Product promise: a payout funded once can never fund a second advance.
    function test_DoubleFundedPayoutReverts() public {
        _creatorApprovesAndRequests();
        registry.setFunder(address(advance));
        vm.prank(creator);
        vm.expectRevert();
        advance.requestAdvance(AMOUNT, payoutId); // same payoutId again
    }

    function test_SecondActiveAdvanceReverts() public {
        _creatorApprovesAndRequests();
        bytes32 payout2 = keccak256("payout-2");
        vm.prank(attester);
        advance.attest(creator, FINAL_BALANCE, 7000, PAYOUT_DATE);
        vm.prank(creator);
        vm.expectRevert();
        advance.requestAdvance(AMOUNT, payout2);
    }

    function test_SettleBeforePayoutDateReverts() public {
        uint256 id = _creatorApprovesAndRequests();
        vm.prank(keeper);
        vm.expectRevert();
        advance.settle(id);
    }

    function test_SettleRepaysThroughWaterfall() public {
        uint256 id = _creatorApprovesAndRequests();
        uint256 seniorDeployedBefore = senior.deployed();
        idrx.mint(creator, REPAY); // Google payout landed on the 21st
        vm.warp(PAYOUT_DATE);
        vm.prank(keeper);
        advance.settle(id);
        // Creator's payout account paid exactly principal + fee.
        assertEq(idrx.balanceOf(creator) - AMOUNT, 0);
        // Principal healed senior; fees landed in tranches.
        assertEq(senior.deployed(), seniorDeployedBefore - AMOUNT);
        assertEq(idrx.balanceOf(address(senior)), 50_000_000_00 + 8_750_000);
        assertEq(idrx.balanceOf(address(junior)), 25_000_000_00 + 2_500_000);
        assertEq(idrx.balanceOf(address(reserve)), 25_000_000_00 + 1_250_000);
        (, CashyAdvance.Status status, , , , ) = advance.advances(id);
        assertEq(uint8(status), uint8(CashyAdvance.Status.Repaid));
        assertFalse(advance.activeAdvanceId(creator) != 0);
    }

    function test_SettleRecordsOnTimeCredit() public {
        uint256 id = _creatorApprovesAndRequests();
        idrx.mint(creator, REPAY);
        vm.warp(PAYOUT_DATE);
        vm.prank(keeper);
        advance.settle(id);
        assertEq(advance.onTimeRepays(creator), 1);
    }

    function test_SettleAfterGraceReverts() public {
        uint256 id = _creatorApprovesAndRequests();
        idrx.mint(creator, REPAY);
        vm.warp(PAYOUT_DATE + 2 days + 1);
        vm.prank(keeper);
        vm.expectRevert();
        advance.settle(id);
    }

    function test_NonSettlerSettleReverts() public {
        uint256 id = _creatorApprovesAndRequests();
        idrx.mint(creator, REPAY);
        vm.warp(PAYOUT_DATE);
        vm.prank(creator);
        vm.expectRevert();
        advance.settle(id);
    }

    function test_MarkDefaultedAfterGrace() public {
        uint256 id = _creatorApprovesAndRequests();
        vm.warp(PAYOUT_DATE + 2 days + 1);
        vm.prank(keeper);
        advance.markDefaulted(id);
        (, CashyAdvance.Status status, , , , ) = advance.advances(id);
        assertEq(uint8(status), uint8(CashyAdvance.Status.Defaulted));
        assertFalse(advance.activeAdvanceId(creator) != 0);
    }
}
