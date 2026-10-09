// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockIDRX
/// @notice Demo rupiah stablecoin for the Cashy hackathon build. Public mint on
///  purpose — a faucet for scripts and tests. Never deploy this to production.
/// @dev 2 decimals so 1 unit = 1 cent; UI money math stores cents to avoid floats.
contract MockIDRX is ERC20 {
    /// @param initialMint Amount minted to the deployer as a starting faucet.
    constructor(uint256 initialMint) ERC20("IDRX Mock", "IDRX") {
        _mint(msg.sender, initialMint);
    }

    /// @notice Fixed 2-decimal precision so token units match the UI's cents.
    /// @return The decimal count.
    function decimals() public pure override returns (uint8) {
        return 2;
    }

    /// @notice Anyone can mint — demo faucet only.
    /// @param to Recipient of the new units.
    /// @param amount Cents to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
