// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC8004IdentityRegistry} from "./interfaces/IERC8004IdentityRegistry.sol";

/// @title AgentSessionModule
/// @notice Scoped session keys, per-tx/cumulative spend caps, expiration, instant revocation,
///         and optional ERC-8004 Identity Registry verification for autonomous AI agent payments.
abstract contract AgentSessionModule {
    struct AgentSession {
        address owner;
        address sessionKey;
        address allowedPayee;
        address agentRegistry;
        uint128 maxPerTxAmount;
        uint128 totalBudget;
        uint128 spent;
        uint64 expiresAt;
        bool active;
        uint256 agentId;
    }

    struct CreateSessionParams {
        address sessionKey;
        address allowedPayee;
        address agentRegistry;
        uint128 maxPerTxAmount;
        uint128 totalBudget;
        uint64 expiresAt;
        uint256 agentId;
    }

    uint256 private _sessionNonce = 1;
    mapping(bytes32 => AgentSession) private _sessions;
    mapping(address => bytes32[]) private _ownerSessions;

    event AgentSessionCreated(
        bytes32 indexed sessionId,
        address indexed owner,
        address indexed sessionKey,
        uint256 agentId,
        address allowedPayee,
        address agentRegistry,
        uint128 maxPerTxAmount,
        uint128 totalBudget,
        uint64 expiresAt
    );
    event AgentSessionRevoked(bytes32 indexed sessionId, address indexed owner, address indexed sessionKey);
    event AgentSessionSpent(
        bytes32 indexed sessionId,
        uint256 indexed invoiceId,
        uint256 indexed agentId,
        uint128 amount,
        uint128 totalSpent,
        uint128 remainingBudget
    );

    error SessionInvalidAddress();
    error SessionInvalidAmount();
    error SessionInvalidDeadline();
    error SessionUnauthorized();
    error SessionPayeeNotVerified();
    error SessionNotFound();
    error SessionInactive();
    error SessionExpired();
    error ExceedsPerTxCap(uint128 amount, uint128 maxPerTxAmount);
    error ExceedsSessionBudget(uint128 amount, uint128 remainingBudget);
    error UnauthorizedPayee();
    error InvalidAgentId();
    error AgentIdentityMismatch();

    /// @notice Grant a scoped session key for `msg.sender` with strict spend caps, expiry, and payee/ERC-8004 bounds.
    function createAgentSession(CreateSessionParams calldata params) external returns (bytes32 sessionId) {
        if (params.sessionKey == address(0)) revert SessionInvalidAddress();
        if (params.maxPerTxAmount == 0 || params.totalBudget == 0 || params.maxPerTxAmount > params.totalBudget) {
            revert SessionInvalidAmount();
        }
        if (params.expiresAt <= block.timestamp) revert SessionInvalidDeadline();

        _verifyAgentIdentity(params.agentRegistry, params.agentId, msg.sender, params.sessionKey);

        sessionId = keccak256(abi.encode(msg.sender, params.sessionKey, params.agentId, _sessionNonce++));
        _sessions[sessionId] = AgentSession({
            owner: msg.sender,
            sessionKey: params.sessionKey,
            allowedPayee: params.allowedPayee,
            agentRegistry: params.agentRegistry,
            maxPerTxAmount: params.maxPerTxAmount,
            totalBudget: params.totalBudget,
            spent: 0,
            expiresAt: params.expiresAt,
            active: true,
            agentId: params.agentId
        });
        _ownerSessions[msg.sender].push(sessionId);

        emit AgentSessionCreated(
            sessionId,
            msg.sender,
            params.sessionKey,
            params.agentId,
            params.allowedPayee,
            params.agentRegistry,
            params.maxPerTxAmount,
            params.totalBudget,
            params.expiresAt
        );
    }

    /// @notice Instantly revoke an active agent session. Callable only by the session owner.
    function revokeAgentSession(bytes32 sessionId) external {
        AgentSession storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert SessionNotFound();
        if (msg.sender != s.owner) revert SessionUnauthorized();
        if (!s.active) revert SessionInactive();

        s.active = false;
        emit AgentSessionRevoked(sessionId, s.owner, s.sessionKey);
    }

    function getAgentSession(bytes32 sessionId) external view returns (AgentSession memory) {
        AgentSession memory s = _sessions[sessionId];
        if (s.owner == address(0)) revert SessionNotFound();
        return s;
    }

    function getOwnerSessions(address owner) external view returns (bytes32[] memory) {
        return _ownerSessions[owner];
    }

    function isSessionActive(bytes32 sessionId) external view returns (bool) {
        AgentSession storage s = _sessions[sessionId];
        return s.owner != address(0) && s.active && block.timestamp <= s.expiresAt && s.spent < s.totalBudget;
    }

    function _consumeAgentSession(
        bytes32 sessionId,
        uint256 invoiceId,
        address payee,
        uint128 amount
    ) internal returns (address payer) {
        AgentSession storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert SessionNotFound();
        if (!s.active) revert SessionInactive();
        if (msg.sender != s.sessionKey) revert SessionUnauthorized();
        if (block.timestamp > s.expiresAt) revert SessionExpired();

        _verifyAgentIdentity(s.agentRegistry, s.agentId, s.owner, s.sessionKey);

        if (s.allowedPayee != address(0)) {
            if (payee != s.allowedPayee) revert UnauthorizedPayee();
        } else {
            // Open-payee sessions require an active Confirmation-of-Payee profile to block unverified drains.
            if (!_isPayeeActive(payee)) revert SessionPayeeNotVerified();
        }

        if (amount > s.maxPerTxAmount) revert ExceedsPerTxCap(amount, s.maxPerTxAmount);
        uint128 remaining = s.totalBudget - s.spent;
        if (amount > remaining) revert ExceedsSessionBudget(amount, remaining);

        s.spent += amount;
        emit AgentSessionSpent(sessionId, invoiceId, s.agentId, amount, s.spent, s.totalBudget - s.spent);

        return s.owner;
    }

    function _verifyAgentIdentity(
        address registry,
        uint256 agentId,
        address owner,
        address sessionKey
    ) private view {
        if (registry == address(0)) return;
        if (agentId == 0) revert InvalidAgentId();
        address regOwner = IERC8004IdentityRegistry(registry).ownerOf(agentId);
        if (regOwner != owner && regOwner != sessionKey) revert AgentIdentityMismatch();
    }

    function _isPayeeActive(address payee) internal view virtual returns (bool);
}
