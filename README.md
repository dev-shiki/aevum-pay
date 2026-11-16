# AevumPay: Verifiable Stablecoin Invoice, Confirmation-of-Payee & Split Escrow Router

[![Live Demo](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages-2ea043)](https://dev-shiki.github.io/aevum-pay/)

Built for **Aevum Builder Challenge #1** on DoraHacks (`https://dorahacks.io/hackathon/qday`).
Live read-only & wallet-enabled prototype: **https://dev-shiki.github.io/aevum-pay/**

## Problem

Stablecoin payments on EVM chains suffer from three practical gaps for merchants and B2B/freelance workflows:
1. **Misdirected transfers (no Confirmation of Payee):** Payers copy-paste raw `0x...` addresses with no on-chain identity binding.
2. **All-or-nothing custody risk:** Direct transfers have no milestone protection or time-locked refund if a counterparty ghosts, while manual multisigs add friction.
3. **Multi-party settlement overhead:** Splitting revenue (merchant + affiliate/referrer + tax/treasury) requires multiple transactions and extra gas.

## Solution

`AevumPayRouter` delivers one cohesive, end-to-end **tUSD8** payment flow on **Aevum Testnet**:
- **On-Chain Confirmation of Payee (CoP):** Payees register unique handles (`registerPayee(handle, metadataHash)`). Invoices can enforce `expectedPayeeHandleHash` at both creation and settlement, reverting if the payee deactivates or mismatches.
- **Direct & Escrowed Modes:**
  - `Direct`: Atomic `tUSD8` settlement with up to 5 configurable basis-point splits (`MAX_BPS = 10_000`).
  - `Escrow`: Payer funds `tUSD8` into the router; payer or arbiter releases to splits on delivery, payer self-refunds after `deadline` (`refundExpiredEscrow`), or `arbiter` resolves disputes (`resolveDispute(invoiceId, payeeBps)`).
- **Scoped Agentic Session Keys & ERC-8004 Guardrails (`AgentSessionModule`):**
  - Owners/smart accounts grant a scoped `sessionKey` via `createAgentSession` with `maxPerTxAmount`, cumulative `totalBudget`, strict `expiresAt`, optional `allowedPayee` pinning (`address(0)` enforces active CoP verification on every payee), and an ERC-8004-compatible `agentId` + optional `IERC8004IdentityRegistry.ownerOf(agentId)` hook.
  - Agents execute payments via `payDirectWithSession(sessionId, invoiceId)` and `fundEscrowWithSession(sessionId, invoiceId)` against the owner's pre-approved `tUSD8` allowance; `fundedBy` is attributed to the owner so escrow refunds and dispute rights remain with the principal.
  - Owners can instantly kill a compromised or runaway agent key with `revokeAgentSession(sessionId)`.
- **ERC-20 & EIP-2612 Support:** Standard `approve` + `transferFrom` for Aevum's `tUSD8` (`0x456569838f1d43009A91ebA4263147Afd7233483`, 6 decimals), plus `*WithPermit` variants for EIP-2612 tokens.

## Architecture

```mermaid
flowchart LR
    P[Payee / Merchant] -->|registerPayee| R[AevumPayRouter]
    P -->|createInvoice Direct/Escrow| R
    U[Payer] -->|confirmPayee| R
    U -->|payDirectInvoice| R
    R -->|atomic splits tUSD8| S[Merchant / Affiliate / Treasury]
    U -->|fundEscrow tUSD8| R
    R -->|releaseEscrow| S
    R -->|refundExpiredEscrow after deadline| U
    A[Arbiter] -->|resolveDispute payeeBps| R
```

## Verified Aevum Testnet Configuration

| Parameter | Value |
|---|---|
| Network Name | QDay Aevum Testnet |
| Chain ID | `44005` (`0xabe5`) |
| RPC URL | `https://rpc-test.qday.info` |
| Native Gas Token | `tQDAY` (18 decimals) |
| Test Stablecoin (`tUSD8`) | `0x456569838f1d43009A91ebA4263147Afd7233483` (6 decimals) |
| Block Explorer | `https://explorer-test.qday.info` |
| Faucet | `https://faucet.qday.info/en` |
| Live Deployed `AevumPayRouter` | [`0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E`](https://explorer-test.qday.info/address/0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E) (Block `3300314`, Deploy Tx: [`0xb71451a2...5dc4bd1`](https://explorer-test.qday.info/tx/0xb71451a2dc4b4c0329d25133de4c6659920389ecc4087f0f8c870b26b5dc4bd1)) |

### Live Verified End-to-End `tUSD8` Transactions (Block `3300689`)

| Step | Action | Explorer Tx |
|---|---|---|
| 1 | `registerPayee("shiki-merchant.aevum")` | [`0xd4aa8bb6...025f50`](https://explorer-test.qday.info/tx/0xd4aa8bb61181f3ecafcc4702284008772b9d95fe16fd01bd819182b1b4025f50) |
| 2 | `tUSD8.approve(AevumPayRouter, 2.00 tUSD8)` | [`0xfba7a786...402e33`](https://explorer-test.qday.info/tx/0xfba7a78608458970934473197295c29a0219b463e87fbac26c76f50b90402e33) |
| 3 | `createInvoice` (1.00 `tUSD8` Direct + CoP) | [`0x141bf70e...ef22fed`](https://explorer-test.qday.info/tx/0x141bf70ee5e72c3283922f5254e6bbb9c18072e6afb2ca6c17e2f81e0ef22fed) |
| 4 | `payDirectInvoice` (1.00 `tUSD8` settled) | [`0x7380aec7...7db35d`](https://explorer-test.qday.info/tx/0x7380aec7d8e300d76bf91ff08896d6b1018989eab557c0bd2d3498c0b67db35d) |
| 5 | `createAgentSession` (ERC-8004 `#1`, 0.50/tx, 1.00 cap) | [`0x7d663db1...feda3d`](https://explorer-test.qday.info/tx/0x7d663db19aa2c23311c849af5b277c5331a746626e49d13824a66508a0feda3d) |
| 6 | `createInvoice` (0.50 `tUSD8` Agent-scoped) | [`0xddfb23db...e7d0e42`](https://explorer-test.qday.info/tx/0xddfb23db85dba1408d917ecb8bff17762c6c0984c3eb9bbd1e05cb985e7d0e42) |
| 7 | `payDirectWithSession` (0.50 `tUSD8` via Agent Session) | [`0xf623ce24...ecfcd8a`](https://explorer-test.qday.info/tx/0xf623ce2494eeed7fe346c4fc3a41cef1d8662ecba4329718158aa3fe9ecfcd8a) |

## Quickstart

### 1. Run Foundry Tests

```bash
forge test -vvv
```

### 2. Check Live Aevum Testnet, Balances & Agent Sessions (Python CLI)

```bash
python cli/aevum_pay_cli.py status
python cli/aevum_pay_cli.py balance 0xYOUR_ADDRESS
python cli/aevum_pay_cli.py session inspect 0xROUTER_ADDRESS --session-id 0xSESSION_ID
python cli/aevum_pay_cli.py session revoke 0xROUTER_ADDRESS --session-id 0xSESSION_ID
```

### 3. Deploy to Aevum Testnet

1. Claim `tQDAY` (gas) and `tUSD8` from `https://faucet.qday.info/en`.
2. Deploy `AevumPayRouter`:

```bash
forge script script/DeployAevumPay.s.sol:DeployAevumPay \
  --rpc-url https://rpc-test.qday.info \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 4. Interactive Prototype UI (Live Web Demo & Docker)

- **Hosted Live Demo (Read-Only Telemetry + MetaMask):** `https://dev-shiki.github.io/aevum-pay/`
- **Local Python Server:** `python -m http.server 8080 --directory frontend`
- **Packaged Docker Image:**

```bash
docker build -t aevumpay-demo .
docker run --rm -p 8080:8080 aevumpay-demo
```

The UI auto-loads live Aevum Testnet state (block height, Confirmation of Payee, invoices, and agent sessions) via `https://rpc-test.qday.info` without requiring a wallet, and switches MetaMask to Chain ID `44005` when connecting.

### 5. Optional Live Escrow & Session Revoke Script

```bash
forge script script/LiveEscrowAndRevoke.s.sol:LiveEscrowAndRevoke \
  --rpc-url https://rpc-test.qday.info \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Security & Controls

- **Reentrancy protection:** Explicit `nonReentrant` lock on all token-moving functions.
- **SafeERC20:** Handles both standard boolean-returning and void-returning ERC-20s.
- **No stuck escrow funds:** `refundExpiredEscrow` is permissionless after `deadline` and always returns `100%` to `fundedBy`.
- **Bounded splits:** Capped at `MAX_SPLITS = 5` with exact `10_000` bps sum validation and deterministic dust assignment to `splits[0]`.
- **Fuzz-tested:** `testFuzz_TokenConservationAcrossDisputeSplits` verifies zero token loss/leakage across arbitrary amounts, split ratios, and dispute outcomes; `testFuzz_AgentSessionSpendCapAndExpiry` verifies per-tx caps, cumulative budget enforcement, and timestamp expiry across arbitrary inputs.
- **Least-privilege agent controls:** Session keys cannot exceed `maxPerTxAmount` or `totalBudget`, cannot pay unverified payees when `allowedPayee == address(0)`, re-verify ERC-8004 ownership on every execution when `agentRegistry != address(0)`, and can be halted immediately via `revokeAgentSession`.
