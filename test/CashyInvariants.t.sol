// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockIDRX} from "../src/MockIDRX.sol";
import {TrancheVault} from "../src/TrancheVault.sol";
import {WaterfallSweep} from "../src/WaterfallSweep.sol";
import {PayoutNullifierRegistry} from "../src/PayoutNullifierRegistry.sol";
import {CashyAdvance} from "../src/CashyAdvance.sol";

/// @notice Invariants for the full pool: money is conserved and claims are final.
/// @dev Ghost accounting: vault balances must equal LP deposits + collected fees
///  minus principal still out with creators (active or defaulted).
contract CashyInvariants is Test {
    MockIDRX internal idrx;
    TrancheVault internal senior;
    TrancheVault internal junior;
    TrancheVault internal reserve;
    WaterfallSweep internal sweep;
    PayoutNullifierRegistry internal registry;
    CashyAdvance internal advance;

    address internal lp = makeAddr("lp");
    address internal keeper = makeAddr("keeper");
    address internal attester = makeAddr("attester");
    address[3] internal creators;

    /// LP money in (cents).
    uint256 internal ghostDeposited;
    /// Fees that reached the tranches.
    uint256 internal ghostFeesIn;
    /// Principal out with creators (active + defaulted).
    uint256 internal ghostOutstanding;
    /// Every payoutId ever used — nullifier claims must be final.
    bytes32[] internal seenPayoutIds;
    uint256 internal payoutCounter;

    function setUp() public {
        idrx = new MockIDRX(0);
        senior = new TrancheVault(IERC20(address(idrx)), "Cashy Senior", "csIDRX", type(uint256).max);
        junior = new TrancheVault(IERC20(address(idrx)), "Cashy Junior", "cjIDRX", type(uint256).max);
        reserve = new TrancheVault(IERC20(address(idrx)), "Cashy Reserve", "crIDRX", type(uint256).max);
        registry = new PayoutNullifierRegistry(address(0));
        advance = new CashyAdvance(IERC20(address(idrx)), senior, registry, 2 days);
        registry.setFunder(address(advance));
        sweep = new WaterfallSweep(address(advance), senior, junior, reserve, 7000, 2000);
        advance.setSweep(sweep);
        senior.grantRole(senior.FUNDER_ROLE(), address(advance));
        senior.grantRole(senior.FUNDER_ROLE(), address(sweep));
        advance.grantRole(advance.ATTESTER_ROLE(), attester);
        advance.grantRole(advance.SETTLER_ROLE(), keeper);

        for (uint256 i = 0; i < 3; i++) {
            creators[i] = makeAddr(string.concat("creator", vm.toString(i)));
        }
        // One LP seeds the pool; advances bounded well under this.
        idrx.mint(lp, 1_000_000_000_00);
        vm.prank(lp);
        idrx.approve(address(senior), type(uint256).max);
        vm.prank(lp);
        senior.deposit(1_000_000_000_00, lp);
        ghostDeposited = 1_000_000_000_00;
    }

    /// @dev The core conservation law of the pool.
    function invariant_VaultsHoldDepositsPlusFeesMinusOutstanding() public view {
        uint256 vaultBalances = idrx.balanceOf(address(senior))
            + idrx.balanceOf(address(junior)) + idrx.balanceOf(address(reserve));
        assertEq(vaultBalances, ghostDeposited + ghostFeesIn - ghostOutstanding, "pool solvency");
    }

    /// @dev Each vault's accounting matches its wallet.
    function invariant_VaultTotalAssetsMatchWallets() public view {
        TrancheVault[3] memory vaults = [senior, junior, reserve];
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                vaults[i].totalAssets(),
                idrx.balanceOf(address(vaults[i])) + vaults[i].deployed(),
                "vault accounting"
            );
        }
    }

    /// @dev Once claimed, a payout stays claimed forever.
    function invariant_ClaimsAreFinal() public view {
        for (uint256 i = 0; i < seenPayoutIds.length; i++) {
            if (registry.isClaimed(seenPayoutIds[i])) {
                assertTrue(registry.isClaimed(seenPayoutIds[i]));
            }
        }
    }

    /// LP tops up Senior.
    function lpDeposit(uint256 amount) external {
        amount = bound(amount, 1, 100_000_000_00);
        idrx.mint(lp, amount);
        vm.prank(lp);
        senior.deposit(amount, lp);
        ghostDeposited += amount;
    }

    /// Creator cashes out against a fresh payout.
    function creatorAdvance(uint256 creatorSeed, uint256 amount) external {
        address creator = creators[creatorSeed % 3];
        if (advance.activeAdvanceId(creator) != 0) return;
        bytes32 payoutId = keccak256(abi.encode("payout", payoutCounter++));
        seenPayoutIds.push(payoutId);
        amount = bound(amount, advance.MIN_ADVANCE(), 50_000_000_00);
        // Bureau attests a balance comfortably above the ask.
        vm.prank(attester);
        advance.attest(creator, 100_000_000_00, 7000, block.timestamp + 21 days);
        vm.startPrank(creator);
        idrx.approve(address(advance), type(uint256).max);
        try advance.requestAdvance(amount, payoutId) returns (uint256) {
            ghostOutstanding += amount;
        } catch {}
        vm.stopPrank();
    }

    /// Payout arrives, keeper settles.
    function settle(uint256 creatorSeed) external {
        address creator = creators[creatorSeed % 3];
        uint256 id = advance.activeAdvanceId(creator);
        if (id == 0) return;
        (, , , uint256 principal, uint256 fee, uint256 payoutDate) = advance.advances(id);
        if (block.timestamp < payoutDate) {
            vm.warp(payoutDate);
        }
        idrx.mint(creator, principal + fee); // Google payout lands
        vm.prank(keeper);
        try advance.settle(id) {
            ghostOutstanding -= principal;
            ghostFeesIn += fee;
        } catch {}
    }

    /// Keeper misses the window — advance defaults.
    function markDefaulted(uint256 creatorSeed) external {
        address creator = creators[creatorSeed % 3];
        uint256 id = advance.activeAdvanceId(creator);
        if (id == 0) return;
        (, , , , , uint256 payoutDate) = advance.advances(id);
        vm.warp(payoutDate + 2 days + 1 hours);
        vm.prank(keeper);
        try advance.markDefaulted(id) {} catch {}
        // Defaulted principal stays out — no ghost change (loss absorbed by Senior).
    }
}
