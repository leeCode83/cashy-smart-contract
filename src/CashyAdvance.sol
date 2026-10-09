// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TrancheVault} from "./TrancheVault.sol";
import {PayoutNullifierRegistry} from "./PayoutNullifierRegistry.sol";
import {WaterfallSweep} from "./WaterfallSweep.sol";

/// @title CashyAdvance
/// @notice Core flow: attest (Bureau rule-based verdict) → requestAdvance (money out of
///  Senior today, payout nullifier claimed) → settle (auto-repay on payout day,
///  fees through the waterfall, on-time credit recorded).
/// @dev The Bureau model itself lives offchain; the chain only stores its verdict
///  (maxBps, payoutDate) via an attester. The keeper settles — in production the
///  rail is licensed open-finance debit, in demo a script after a time warp.
/// ponytail: defaulted advances stay on Senior's books (no junior loss
///  absorption in code); add loss-waterfall accounting when demo needs it.
contract CashyAdvance is AccessControl {
    using SafeERC20 for IERC20;

    /// @notice Sets the Bureau verdict per creator.
    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    /// @notice Runs settlements (keeper / demo script).
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @notice Flat fee: 250 bps = 2.5%, no interest, visible up front.
    uint256 public constant FEE_BPS = 250;
    /// @notice Minimum advance 100,000.00 IDRX (cents).
    uint256 public constant MIN_ADVANCE = 10_000_000;

    /// @notice Advance lifecycle shown in the UI.
    enum Status {
        Active,
        Repaid,
        Defaulted
    }

    /// @notice Bureau verdict for one creator.
    /// @param finalBalance AdSense final balance in cents (attested, not guessed).
    /// @param maxBps Share of final balance cash-out-able (e.g. 7000 = 70%).
    /// @param payoutDate Timestamp Google pays out (the 21st).
    struct Attestation {
        uint256 finalBalance;
        uint256 maxBps;
        uint256 payoutDate;
    }

    /// @notice One advance.
    /// @param creator Recipient.
    /// @param status Lifecycle.
    /// @param payoutId Nullifier of the funded payout.
    /// @param principal Cents handed out today.
    /// @param fee Flat fee in cents; repay = principal + fee.
    /// @param payoutDate When auto-repay runs.
    struct Advance {
        address creator;
        Status status;
        bytes32 payoutId;
        uint256 principal;
        uint256 fee;
        uint256 payoutDate;
    }

    /// @notice creator => current Bureau verdict.
    mapping(address => Attestation) public attestations;
    /// @notice id => advance record.
    mapping(uint256 => Advance) public advances;
    /// @notice creator => id of their open advance; 0 when none.
    mapping(address => uint256) public activeAdvanceId;
    /// @notice creator => count of on-time repayments — the portable credit record.
    mapping(address => uint256) public onTimeRepays;

    /// @notice Monotonic advance id.
    uint256 public nextId = 1;

    /// @notice Senior vault that funds advances and heals on repayment.
    TrancheVault public immutable SENIOR;
    /// @notice Registry ensuring a payout is funded exactly once.
    PayoutNullifierRegistry public immutable REGISTRY;
    /// @notice Token moving between creator, vaults and sweep.
    IERC20 public immutable TOKEN;
    /// @notice Days after payoutDate before an unsettled advance defaults.
    uint256 public immutable GRACE_PERIOD;

    /// @notice Set once after deploy — sweep references this contract, so it
    ///  cannot be passed in the constructor.
    WaterfallSweep public sweep;

    /// @notice No Bureau verdict for this creator yet.
    error NotAttested();
    /// @notice Amount above the attested limit.
    error NotEligible();
    /// @notice Amount under MIN_ADVANCE.
    error BelowMinimum();
    /// @notice Creator already has an open advance.
    error ActiveAdvanceExists();
    /// @notice Wrong lifecycle state or wrong time for this action.
    error NotSettleable();
    /// @notice Caller is not the keeper.
    error NotKeeper();
    /// @notice Sweep not wired yet.
    error SweepNotSet();

    /// @notice Advance funded; powers dashboards and explorers.
    /// @param id Advance id.
    /// @param creator Recipient.
    /// @param principal Cents handed out.
    /// @param fee Flat fee in cents.
    event AdvanceCreated(uint256 indexed id, address indexed creator, uint256 principal, uint256 fee);

    /// @notice Auto-repay succeeded on time; credit record grows.
    /// @param creator Repayer.
    /// @param id Advance id.
    event RepaidOnTime(address indexed creator, uint256 indexed id);

    /// @notice Advance written off after the grace period.
    /// @param id Advance id.
    event Defaulted(uint256 indexed id);

    /// @param token_ IDRX stablecoin.
    /// @param senior_ Senior tranche vault funding the advances.
    /// @param registry_ Payout nullifier registry.
    /// @param gracePeriod_ Seconds after payoutDate before default.
    constructor(IERC20 token_, TrancheVault senior_, PayoutNullifierRegistry registry_, uint256 gracePeriod_) {
        TOKEN = token_;
        SENIOR = senior_;
        REGISTRY = registry_;
        GRACE_PERIOD = gracePeriod_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Admin wires the waterfall (deploy-time, same circularity as registry).
    /// @param sweep_ WaterfallSweep that splits repayments.
    function setSweep(WaterfallSweep sweep_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sweep = sweep_;
    }

    /// @notice Bureau attests a creator's verified final balance and cash-out cap.
    /// @param creator Attested account.
    /// @param finalBalance AdSense final balance in cents.
    /// @param maxBps Cash-out cap in bps of finalBalance.
    /// @param payoutDate Google payout timestamp (the 21st).
    function attest(address creator, uint256 finalBalance, uint256 maxBps, uint256 payoutDate)
        external
        onlyRole(ATTESTER_ROLE)
    {
        attestations[creator] = Attestation({finalBalance: finalBalance, maxBps: maxBps, payoutDate: payoutDate});
    }

    /// @notice Fee and repay totals for an amount — what the UI shows up front.
    /// @param amount Advance principal in cents.
    /// @return fee Flat 2.5% fee in cents.
    /// @return repay principal + fee.
    function previewFee(uint256 amount) external pure returns (uint256 fee, uint256 repay) {
        fee = (amount * FEE_BPS) / 10_000;
        repay = amount + fee;
    }

    /// @notice Cash out part of an attested final balance today.
    /// @dev Pulls from Senior, claims the payout nullifier first — one payout,
    ///  one advance, ever. Creator must have approved `token` for the future repay.
    /// @param amount Principal in cents; 2.5% fee is added at repayment.
    /// @param payoutId Nullifier of the attested payout.
    /// @return id New advance id.
    function requestAdvance(uint256 amount, bytes32 payoutId) external returns (uint256 id) {
        Attestation memory a = attestations[msg.sender];
        if (a.finalBalance == 0) revert NotAttested();
        if (activeAdvanceId[msg.sender] != 0) revert ActiveAdvanceExists();
        if (amount < MIN_ADVANCE) revert BelowMinimum();
        if (amount > (a.finalBalance * a.maxBps) / 10_000) revert NotEligible();

        REGISTRY.claim(payoutId, msg.sender);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        SENIOR.deploy(msg.sender, amount);

        id = nextId++;
        advances[id] = Advance({
            creator: msg.sender,
            status: Status.Active,
            payoutId: payoutId,
            principal: amount,
            fee: fee,
            payoutDate: a.payoutDate
        });
        activeAdvanceId[msg.sender] = id;
        emit AdvanceCreated(id, msg.sender, amount, fee);
    }

    /// @notice Keeper collects principal + fee from the creator's payout account
    ///  (pre-approved), returns principal to Senior and pushes fees through the
    ///  waterfall, then records the on-time credit.
    /// @param id Advance to settle.
    function settle(uint256 id) external onlyRole(SETTLER_ROLE) {
        Advance storage adv = advances[id];
        if (adv.status != Status.Active) revert NotSettleable();
        if (block.timestamp < adv.payoutDate) revert NotSettleable();
        if (block.timestamp > adv.payoutDate + GRACE_PERIOD) revert NotSettleable();

        // Effects first: the advance is done before any token moves.
        adv.status = Status.Repaid;
        activeAdvanceId[adv.creator] = 0;
        onTimeRepays[adv.creator] += 1;

        uint256 principal = adv.principal;
        TOKEN.safeTransferFrom(adv.creator, address(sweep), principal + adv.fee);
        sweep.distribute(principal, adv.fee);
        SENIOR.settleRepaid(principal);

        emit RepaidOnTime(adv.creator, id);
    }

    /// @notice Keeper writes off an advance past its grace period.
    /// @param id Advance to default.
    function markDefaulted(uint256 id) external onlyRole(SETTLER_ROLE) {
        Advance storage adv = advances[id];
        if (adv.status != Status.Active) revert NotSettleable();
        if (block.timestamp <= adv.payoutDate + GRACE_PERIOD) revert NotSettleable();
        adv.status = Status.Defaulted;
        activeAdvanceId[adv.creator] = 0;
        emit Defaulted(id);
    }
}
