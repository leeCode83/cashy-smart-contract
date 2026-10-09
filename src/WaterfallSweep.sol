// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TrancheVault} from "./TrancheVault.sol";

/// @title WaterfallSweep
/// @notice Splits a settled repayment (principal + fee) across the three pool
///  tranches. Principal returns 100% to Senior so its deployed assets heal; the
///  flat fee is the LP yield, split by a fixed ratio — transferred in without
///  minting shares, so each tranche's share price rises.
/// ponytail: fixed fee ratios, not per-tranche yield targets; upgrade to
///  target-based waterfall when demo shows waterfall absorption to juries.
contract WaterfallSweep {
    using SafeERC20 for IERC20;

    /// @notice May push settled funds into the tranches.
    address public immutable SETTLER;

    /// @notice Where principal heals and the senior fee cut lands.
    TrancheVault public immutable SENIOR;
    /// @notice Middle fee cut.
    TrancheVault public immutable JUNIOR;
    /// @notice Last fee cut; absorbs rounding dust.
    TrancheVault public immutable RESERVE;

    /// @notice IDRX being distributed.
    IERC20 public immutable TOKEN;

    /// @notice Senior fee cut in bps of the fee (default 7000).
    uint256 public seniorBps;
    /// @notice Junior fee cut in bps of the fee (default 2000). Rest goes to Reserve.
    uint256 public juniorBps;

    /// @notice Fee ratio cuts must sum to 10,000 bps.
    error InvalidRatios();

    /// @notice Caller is not the settler.
    error NotSettler();

    /// @param settler_ CashyAdvance contract — sole caller of distribute.
    /// @param senior_ Senior tranche vault.
    /// @param junior_ Junior tranche vault.
    /// @param reserve_ Reserve tranche vault.
    /// @param seniorBps_ Senior cut of each fee, in bps.
    /// @param juniorBps_ Junior cut of each fee, in bps.
    constructor(
        address settler_,
        TrancheVault senior_,
        TrancheVault junior_,
        TrancheVault reserve_,
        uint256 seniorBps_,
        uint256 juniorBps_
    ) {
        if (seniorBps_ + juniorBps_ > 10_000) revert InvalidRatios();
        SETTLER = settler_;
        SENIOR = senior_;
        JUNIOR = junior_;
        RESERVE = reserve_;
        TOKEN = IERC20(senior_.asset());
        seniorBps = seniorBps_;
        juniorBps = juniorBps_;
    }

    /// @notice Owner-only ratio update; sums must stay within 10,000 bps.
    /// @param seniorBps_ New senior cut in bps.
    /// @param juniorBps_ New junior cut in bps.
    function setRatios(uint256 seniorBps_, uint256 juniorBps_) external {
        if (msg.sender != SETTLER) revert NotSettler();
        if (seniorBps_ + juniorBps_ > 10_000) revert InvalidRatios();
        seniorBps = seniorBps_;
        juniorBps = juniorBps_;
    }

    /// @notice Push one settled repayment into the tranches. Call after the
    ///  repay amount (principal + fee) has arrived at this contract.
    /// @param principal Advance principal returning to Senior.
    /// @param fee Flat fee to split as LP yield.
    function distribute(uint256 principal, uint256 fee) external {
        if (msg.sender != SETTLER) revert NotSettler();
        TOKEN.safeTransfer(address(SENIOR), principal);
        uint256 toSenior = (fee * seniorBps) / 10_000;
        uint256 toJunior = (fee * juniorBps) / 10_000;
        // Reserve takes the remaining cut plus rounding dust — nothing is lost.
        uint256 toReserve = fee - toSenior - toJunior;
        TOKEN.safeTransfer(address(SENIOR), toSenior);
        TOKEN.safeTransfer(address(JUNIOR), toJunior);
        TOKEN.safeTransfer(address(RESERVE), toReserve);
    }
}
