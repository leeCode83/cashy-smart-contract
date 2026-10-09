// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title TrancheVault
/// @notice One ERC-4626 vault per pool tranche (Senior, Junior, Reserve). LPs
///  deposit the IDRX stablecoin and earn yield because repayment fees are
///  transferred into the vault without minting shares — share price rises.
/// @dev The same contract is deployed three times; tranches differ only by
///  capacity and who holds roles. Funder = the CashyAdvance contract.
contract TrancheVault is ERC4626, AccessControl {
    /// @notice May pull idle assets out to fund an advance and settle repayments back.
    bytes32 public constant FUNDER_ROLE = keccak256("FUNDER_ROLE");

    /// @notice Assets currently deployed to creators (not in the vault wallet).
    uint256 public deployed;

    /// @notice Hard deposit ceiling for this tranche; max for uncapped.
    uint256 public immutable capacity;

    /// @notice No free liquidity left to fund an advance.
    error InsufficientLiquidity();

    /// @notice Accounting invariant broke: deployed exceeds vault assets.
    error DeployExceedsAssets();

    /// @param asset_ IDRX stablecoin (2 decimals).
    /// @param name_ ERC-20 name, e.g. "Cashy Senior".
    /// @param symbol_ ERC-20 symbol, e.g. "csIDRX".
    /// @param capacity_ Max total deposits; pass type(uint256).max for uncapped.
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 capacity_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        capacity = capacity_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Deposit cap equals remaining tranche capacity ("Capacity left" in UI).
    /// @return Remaining depositable assets.
    function maxDeposit(address) public view override returns (uint256) {
        uint256 assets = totalAssets();
        return assets >= capacity ? 0 : capacity - assets;
    }

    /// @notice Assets = wallet balance + what is out with creators.
    /// @return Total tranche assets backing all shares.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployed;
    }

    /// @notice Funder moves idle assets to a creator as an advance.
    /// @param to Creator receiving the advance.
    /// @param amount Cents to hand out.
    function deploy(address to, uint256 amount) external onlyRole(FUNDER_ROLE) {
        if (amount > IERC20(asset()).balanceOf(address(this))) revert InsufficientLiquidity();
        if (deployed + amount > totalAssets()) revert DeployExceedsAssets();
        deployed += amount;
        IERC20(asset()).transfer(to, amount);
    }

    /// @notice Funder records that principal came back after a settlement.
    /// @dev Call after the sweep has already transferred principal into the vault.
    /// @param amount Principal cents that returned.
    function settleRepaid(uint256 amount) external onlyRole(FUNDER_ROLE) {
        deployed -= amount;
    }
}
