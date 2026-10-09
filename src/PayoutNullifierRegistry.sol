// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PayoutNullifierRegistry
/// @notice Shared onchain truth that one AdSense payout can be funded by only one
///  lender. Any competing app reads it for free — this is Cashy's "why onchain".
/// @dev payoutId should be a hash of the verified attestation (e.g. zkTLS proof
///  digest), never raw account data — keeps creator balance private.
contract PayoutNullifierRegistry {
    /// @notice Admin (deployer) — may hand the funder role to another contract.
    address public immutable admin;

    /// @notice Only callers holding the funder role may claim payouts.
    address public funder;

    /// @notice payoutId => true once an advance has funded that payout.
    mapping(bytes32 => bool) public claimed;

    /// @notice Payout already funded — the anti-stacking guarantee.
    error AlreadyClaimed();

    /// @notice Caller is not the authorized funding contract.
    error NotFunder();

    /// @notice Caller is not the admin.
    error NotAdmin();

    /// @notice Emitted on every claim; powers the vault UI live feed.
    /// @param payoutId Nullifier of the funded payout.
    /// @param creator Creator who received the advance.
    event PayoutClaimed(bytes32 indexed payoutId, address indexed creator);

    /// @param _funder Address allowed to claim (the CashyAdvance contract).
    constructor(address _funder) {
        admin = msg.sender;
        funder = _funder;
    }

    /// @notice Admin retargets the funder — needed once because the funding
    ///  contract and this registry reference each other at deploy time.
    /// @param funder_ New authorized claiming contract.
    function setFunder(address funder_) external {
        if (msg.sender != admin) revert NotAdmin();
        funder = funder_;
    }

    /// @notice Mark a payout as funded. Reverts if it was already funded once.
    /// @param payoutId Nullifier of the payout being advanced against.
    /// @param creator Creator receiving the advance.
    function claim(bytes32 payoutId, address creator) external {
        if (msg.sender != funder) revert NotFunder();
        if (claimed[payoutId]) revert AlreadyClaimed();
        claimed[payoutId] = true;
        emit PayoutClaimed(payoutId, creator);
    }

    /// @notice Free read for any lender: has this payout been funded?
    /// @param payoutId Nullifier to check.
    /// @return True once claimed; a claim can never be undone.
    function isClaimed(bytes32 payoutId) external view returns (bool) {
        return claimed[payoutId];
    }
}
