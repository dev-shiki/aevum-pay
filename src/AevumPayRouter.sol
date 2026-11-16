// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IERC20Permit} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {AgentSessionModule} from "./AgentSessionModule.sol";

/// @title AevumPayRouter
/// @notice Stablecoin invoice, Confirmation-of-Payee registry, split-settlement escrow, and scoped AI agent session router for Aevum Testnet (tUSD8).
contract AevumPayRouter is AgentSessionModule {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;
    uint8 public constant MAX_SPLITS = 5;

    enum PaymentMode {
        Direct,
        Escrow
    }

    enum InvoiceStatus {
        Open,
        Funded,
        Paid,
        Refunded,
        Disputed,
        Cancelled
    }

    struct Split {
        address recipient;
        uint16 bps;
    }

    struct PayeeProfile {
        bytes32 handleHash;
        bytes32 metadataHash;
        uint64 updatedAt;
        bool active;
        string handle;
    }

    struct Invoice {
        address token;
        address payee;
        address expectedPayer;
        address fundedBy;
        address arbiter;
        uint128 amount;
        uint64 deadline;
        uint64 createdAt;
        uint64 settledAt;
        PaymentMode mode;
        InvoiceStatus status;
        bytes32 expectedPayeeHandleHash;
        bytes32 memoHash;
    }

    struct CreateInvoiceParams {
        address token;
        address expectedPayer;
        address arbiter;
        uint128 amount;
        uint64 deadline;
        PaymentMode mode;
        bytes32 expectedPayeeHandleHash;
        bytes32 memoHash;
        Split[] splits;
    }

    uint256 private _nextInvoiceId = 1;
    uint256 private _locked = 1;

    mapping(address => PayeeProfile) private _payees;
    mapping(bytes32 => address) public handleOwner;
    mapping(uint256 => Invoice) private _invoices;
    mapping(uint256 => Split[]) private _invoiceSplits;

    event PayeeRegistered(address indexed payee, bytes32 indexed handleHash, string handle, bytes32 metadataHash);
    event PayeeDeactivated(address indexed payee, bytes32 indexed handleHash);
    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed payee,
        address indexed token,
        uint128 amount,
        PaymentMode mode,
        uint64 deadline,
        bytes32 expectedPayeeHandleHash,
        bytes32 memoHash
    );
    event InvoicePaid(uint256 indexed invoiceId, address indexed payer, uint128 amount);
    event EscrowFunded(uint256 indexed invoiceId, address indexed payer, uint128 amount);
    event EscrowReleased(uint256 indexed invoiceId, address indexed caller, uint128 amount);
    event EscrowRefunded(uint256 indexed invoiceId, address indexed payer, uint128 amount);
    event EscrowDisputed(uint256 indexed invoiceId, address indexed caller, bytes32 reasonHash);
    event DisputeResolved(
        uint256 indexed invoiceId,
        address indexed arbiter,
        uint128 payeeAmount,
        uint128 payerRefundAmount
    );
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed payee);

    error Reentrancy();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidHandle();
    error HandleTaken();
    error PayeeMismatch();
    error InvalidSplits();
    error InvoiceNotFound();
    error InvalidStatus(InvoiceStatus expected, InvoiceStatus actual);
    error InvalidMode(PaymentMode expected, PaymentMode actual);
    error Unauthorized();
    error DeadlineNotReached();
    error DeadlineExpired();
    error InvalidBps();

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Register or update a Confirmation-of-Payee profile for `msg.sender`.
    function registerPayee(string calldata handle, bytes32 metadataHash) external {
        bytes memory raw = bytes(handle);
        if (raw.length == 0 || raw.length > 64) revert InvalidHandle();

        bytes32 hHash = keccak256(raw);
        address currentOwner = handleOwner[hHash];
        if (currentOwner != address(0) && currentOwner != msg.sender) revert HandleTaken();

        bytes32 oldHash = _payees[msg.sender].handleHash;
        if (oldHash != bytes32(0) && oldHash != hHash) {
            delete handleOwner[oldHash];
        }

        handleOwner[hHash] = msg.sender;
        _payees[msg.sender] = PayeeProfile({
            handleHash: hHash,
            metadataHash: metadataHash,
            updatedAt: uint64(block.timestamp),
            active: true,
            handle: handle
        });

        emit PayeeRegistered(msg.sender, hHash, handle, metadataHash);
    }

    /// @notice Deactivate the caller's Confirmation-of-Payee profile.
    function deactivatePayee() external {
        PayeeProfile storage profile = _payees[msg.sender];
        if (!profile.active) revert InvalidHandle();
        profile.active = false;
        profile.updatedAt = uint64(block.timestamp);
        emit PayeeDeactivated(msg.sender, profile.handleHash);
    }

    /// @notice Verify whether `payee` is active and matches `expectedHandleHash`.
    function confirmPayee(
        address payee,
        bytes32 expectedHandleHash
    ) external view returns (bool verified, string memory handle, bytes32 metadataHash) {
        PayeeProfile storage profile = _payees[payee];
        verified = profile.active && profile.handleHash != bytes32(0) && profile.handleHash == expectedHandleHash;
        return (verified, profile.handle, profile.metadataHash);
    }

    function getPayeeProfile(address payee) external view returns (PayeeProfile memory) {
        return _payees[payee];
    }

    /// @notice Create a Direct or Escrow invoice with optional Confirmation-of-Payee enforcement and multi-recipient splits.
    function createInvoice(CreateInvoiceParams calldata params) external returns (uint256 invoiceId) {
        if (params.token == address(0)) revert InvalidAddress();
        if (params.amount == 0) revert InvalidAmount();
        if (params.deadline <= block.timestamp) revert InvalidDeadline();
        if (params.expectedPayeeHandleHash != bytes32(0)) {
            _requireVerifiedPayee(msg.sender, params.expectedPayeeHandleHash);
        }

        _validateSplits(params.splits);

        invoiceId = _nextInvoiceId++;
        _invoices[invoiceId] = Invoice({
            token: params.token,
            payee: msg.sender,
            expectedPayer: params.expectedPayer,
            fundedBy: address(0),
            arbiter: params.arbiter,
            amount: params.amount,
            deadline: params.deadline,
            createdAt: uint64(block.timestamp),
            settledAt: 0,
            mode: params.mode,
            status: InvoiceStatus.Open,
            expectedPayeeHandleHash: params.expectedPayeeHandleHash,
            memoHash: params.memoHash
        });

        Split[] storage stored = _invoiceSplits[invoiceId];
        for (uint256 i = 0; i < params.splits.length; i++) {
            stored.push(params.splits[i]);
        }

        emit InvoiceCreated(
            invoiceId,
            msg.sender,
            params.token,
            params.amount,
            params.mode,
            params.deadline,
            params.expectedPayeeHandleHash,
            params.memoHash
        );
    }

    /// @notice Pay a Direct invoice using prior ERC-20 allowance (`approve` + `transferFrom`).
    function payDirectInvoice(uint256 invoiceId) external nonReentrant {
        _payDirect(invoiceId, msg.sender);
    }

    /// @notice Pay a Direct invoice atomically using an EIP-2612 permit signature.
    function payDirectInvoiceWithPermit(
        uint256 invoiceId,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        IERC20Permit(inv.token).permit(msg.sender, address(this), inv.amount, permitDeadline, v, r, s);
        _payDirect(invoiceId, msg.sender);
    }

    /// @notice Pay a Direct invoice via an authorized AI agent session key within per-tx and total spend caps.
    function payDirectWithSession(bytes32 sessionId, uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Direct) revert InvalidMode(PaymentMode.Direct, inv.mode);
        address payer = _consumeAgentSession(sessionId, invoiceId, inv.payee, inv.amount);
        _payDirect(invoiceId, payer);
    }

    /// @notice Deposit `tUSD8` into an Escrow invoice.
    function fundEscrow(uint256 invoiceId) external nonReentrant {
        _fundEscrow(invoiceId, msg.sender);
    }

    /// @notice Deposit `tUSD8` into an Escrow invoice atomically using an EIP-2612 permit signature.
    function fundEscrowWithPermit(
        uint256 invoiceId,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        IERC20Permit(inv.token).permit(msg.sender, address(this), inv.amount, permitDeadline, v, r, s);
        _fundEscrow(invoiceId, msg.sender);
    }

    /// @notice Deposit `tUSD8` into an Escrow invoice via an authorized AI agent session key within guardrails.
    function fundEscrowWithSession(bytes32 sessionId, uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        address payer = _consumeAgentSession(sessionId, invoiceId, inv.payee, inv.amount);
        _fundEscrow(invoiceId, payer);
    }

    /// @notice Release funded escrow to configured split recipients. Callable by the payer or arbiter.
    function releaseEscrow(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        if (inv.status != InvoiceStatus.Funded) revert InvalidStatus(InvoiceStatus.Funded, inv.status);
        if (msg.sender != inv.fundedBy && msg.sender != inv.arbiter) revert Unauthorized();

        inv.status = InvoiceStatus.Paid;
        inv.settledAt = uint64(block.timestamp);

        _distributeSplits(IERC20(inv.token), address(this), _invoiceSplits[invoiceId], inv.amount, false);
        emit EscrowReleased(invoiceId, msg.sender, inv.amount);
    }

    /// @notice Self-refund an expired Funded escrow back to the payer after `deadline`.
    function refundExpiredEscrow(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        if (inv.status != InvoiceStatus.Funded) revert InvalidStatus(InvoiceStatus.Funded, inv.status);
        if (block.timestamp <= inv.deadline) revert DeadlineNotReached();

        inv.status = InvoiceStatus.Refunded;
        inv.settledAt = uint64(block.timestamp);

        IERC20(inv.token).safeTransfer(inv.fundedBy, inv.amount);
        emit EscrowRefunded(invoiceId, inv.fundedBy, inv.amount);
    }

    /// @notice Flag a Funded escrow as Disputed before deadline (requires an arbiter).
    function disputeEscrow(uint256 invoiceId, bytes32 reasonHash) external {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        if (inv.status != InvoiceStatus.Funded) revert InvalidStatus(InvoiceStatus.Funded, inv.status);
        if (inv.arbiter == address(0)) revert InvalidAddress();
        if (msg.sender != inv.fundedBy && msg.sender != inv.payee) revert Unauthorized();
        if (block.timestamp > inv.deadline) revert DeadlineExpired();

        inv.status = InvoiceStatus.Disputed;
        emit EscrowDisputed(invoiceId, msg.sender, reasonHash);
    }

    /// @notice Resolve a Funded or Disputed escrow by splitting between payee splits (`payeeBps`) and payer.
    function resolveDispute(uint256 invoiceId, uint16 payeeBps) external nonReentrant {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        if (inv.status != InvoiceStatus.Disputed && inv.status != InvoiceStatus.Funded) {
            revert InvalidStatus(InvoiceStatus.Disputed, inv.status);
        }
        if (msg.sender != inv.arbiter || inv.arbiter == address(0)) revert Unauthorized();
        if (payeeBps > MAX_BPS) revert InvalidBps();

        uint128 payeeAmount = uint128((uint256(inv.amount) * payeeBps) / MAX_BPS);
        uint128 payerRefund = inv.amount - payeeAmount;

        inv.status = payeeAmount == 0 ? InvoiceStatus.Refunded : InvoiceStatus.Paid;
        inv.settledAt = uint64(block.timestamp);

        IERC20 token = IERC20(inv.token);
        if (payeeAmount > 0) {
            _distributeSplits(token, address(this), _invoiceSplits[invoiceId], payeeAmount, false);
        }
        if (payerRefund > 0) {
            token.safeTransfer(inv.fundedBy, payerRefund);
        }

        emit DisputeResolved(invoiceId, msg.sender, payeeAmount, payerRefund);
    }

    /// @notice Cancel an Open (unpaid/unfunded) invoice. Callable only by the payee.
    function cancelOpenInvoice(uint256 invoiceId) external {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.status != InvoiceStatus.Open) revert InvalidStatus(InvoiceStatus.Open, inv.status);
        if (msg.sender != inv.payee) revert Unauthorized();

        inv.status = InvoiceStatus.Cancelled;
        inv.settledAt = uint64(block.timestamp);
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory, Split[] memory) {
        Invoice memory inv = _getInvoice(invoiceId);
        return (inv, _invoiceSplits[invoiceId]);
    }

    function nextInvoiceId() external view returns (uint256) {
        return _nextInvoiceId;
    }

    function _payDirect(uint256 invoiceId, address payer) private {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Direct) revert InvalidMode(PaymentMode.Direct, inv.mode);
        _validateOpenForPayment(inv, payer);

        inv.fundedBy = payer;
        inv.status = InvoiceStatus.Paid;
        inv.settledAt = uint64(block.timestamp);

        _distributeSplits(IERC20(inv.token), payer, _invoiceSplits[invoiceId], inv.amount, true);
        emit InvoicePaid(invoiceId, payer, inv.amount);
    }

    function _fundEscrow(uint256 invoiceId, address payer) private {
        Invoice storage inv = _getInvoice(invoiceId);
        if (inv.mode != PaymentMode.Escrow) revert InvalidMode(PaymentMode.Escrow, inv.mode);
        _validateOpenForPayment(inv, payer);

        inv.fundedBy = payer;
        inv.status = InvoiceStatus.Funded;

        IERC20(inv.token).safeTransferFrom(payer, address(this), inv.amount);
        emit EscrowFunded(invoiceId, payer, inv.amount);
    }

    function _validateOpenForPayment(Invoice storage inv, address payer) private view {
        if (inv.status != InvoiceStatus.Open) revert InvalidStatus(InvoiceStatus.Open, inv.status);
        if (block.timestamp > inv.deadline) revert DeadlineExpired();
        if (inv.expectedPayer != address(0) && payer != inv.expectedPayer) revert Unauthorized();
        if (inv.expectedPayeeHandleHash != bytes32(0)) {
            _requireVerifiedPayee(inv.payee, inv.expectedPayeeHandleHash);
        }
    }

    function _isPayeeActive(address payee) internal view override returns (bool) {
        PayeeProfile storage profile = _payees[payee];
        return profile.active && profile.handleHash != bytes32(0);
    }

    function _requireVerifiedPayee(address payee, bytes32 expectedHandleHash) private view {
        PayeeProfile storage profile = _payees[payee];
        if (!profile.active || profile.handleHash != expectedHandleHash) {
            revert PayeeMismatch();
        }
    }

    function _validateSplits(Split[] calldata splits) private pure {
        if (splits.length == 0 || splits.length > MAX_SPLITS) revert InvalidSplits();
        uint256 totalBps;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].recipient == address(0) || splits[i].bps == 0) revert InvalidSplits();
            totalBps += splits[i].bps;
        }
        if (totalBps != MAX_BPS) revert InvalidSplits();
    }

    /// @dev Distributes `totalAmount` across `splits`; sends any integer rounding dust to the first recipient.
    function _distributeSplits(
        IERC20 token,
        address from,
        Split[] storage splits,
        uint256 totalAmount,
        bool pullFromPayer
    ) private {
        uint256 len = splits.length;
        uint256 distributed;
        for (uint256 i = 1; i < len; i++) {
            uint256 share = (totalAmount * splits[i].bps) / MAX_BPS;
            distributed += share;
            if (share > 0) {
                if (pullFromPayer) {
                    token.safeTransferFrom(from, splits[i].recipient, share);
                } else {
                    token.safeTransfer(splits[i].recipient, share);
                }
            }
        }
        uint256 firstShare = totalAmount - distributed;
        if (firstShare > 0) {
            if (pullFromPayer) {
                token.safeTransferFrom(from, splits[0].recipient, firstShare);
            } else {
                token.safeTransfer(splits[0].recipient, firstShare);
            }
        }
    }

    function _getInvoice(uint256 invoiceId) private view returns (Invoice storage inv) {
        inv = _invoices[invoiceId];
        if (inv.createdAt == 0) revert InvoiceNotFound();
    }
}
