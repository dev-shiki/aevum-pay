#!/usr/bin/env python3
"""
AevumPay CLI - Zero-dependency Python tool for Aevum Testnet (Chain ID 44005).
Checks RPC health, tUSD8 balances, Confirmation-of-Payee status, and prints cast/forge commands.
"""

import argparse
import json
import sys
import urllib.request

RPC_URL = "https://rpc-test.qday.info"
CHAIN_ID = 44005
TUSD8_ADDRESS = "0x456569838f1d43009A91ebA4263147Afd7233483"
EXPLORER_URL = "https://explorer-test.qday.info"
FAUCET_URL = "https://faucet.qday.info/en"


def rpc_call(method: str, params: list, rpc_url: str = RPC_URL):
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(
        rpc_url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "AevumPayCLI/1.0"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if "error" in data:
            raise RuntimeError(f"RPC error: {data['error']}")
        return data["result"]


def pad_address(addr: str) -> str:
    clean = addr.lower().removeprefix("0x")
    if len(clean) != 40:
        raise ValueError(f"Invalid EVM address: {addr}")
    return clean.rjust(64, "0")


def cmd_status(args):
    chain_hex = rpc_call("eth_chainId", [], args.rpc)
    block_hex = rpc_call("eth_blockNumber", [], args.rpc)
    decimals_hex = rpc_call("eth_call", [{"to": TUSD8_ADDRESS, "data": "0x313ce567"}, "latest"], args.rpc)
    print(f"RPC URL      : {args.rpc}")
    print(f"Chain ID     : {int(chain_hex, 16)} ({chain_hex})")
    print(f"Block Number : {int(block_hex, 16)}")
    print(f"tUSD8 Token  : {TUSD8_ADDRESS} (decimals: {int(decimals_hex, 16)})")
    print(f"Explorer     : {EXPLORER_URL}")
    print(f"Faucet       : {FAUCET_URL}")


def cmd_balance(args):
    native_hex = rpc_call("eth_getBalance", [args.address, "latest"], args.rpc)
    tusd8_hex = rpc_call(
        "eth_call",
        [{"to": TUSD8_ADDRESS, "data": "0x70a08231" + pad_address(args.address)}, "latest"],
        args.rpc,
    )
    tqday = int(native_hex, 16) / 1e18
    tusd8 = int(tusd8_hex, 16) / 1e6
    print(f"Address      : {args.address}")
    print(f"tQDAY (gas)  : {tqday:.6f} tQDAY")
    print(f"tUSD8        : {tusd8:.6f} tUSD8")


def cmd_invoice(args):
    # getInvoice(uint256) selector: 0x9935f2c0 -> compute via cast or keccak; use raw hex if known or print cast cmd
    print("Querying invoice via cast:")
    print(f'cast call {args.router} "getInvoice(uint256)" {args.invoice_id} --rpc-url {args.rpc}')


def cmd_session(args):
    if args.action == "inspect":
        if not args.session_id:
            raise ValueError("--session-id is required for inspect")
        print("Inspecting agent session via cast:")
        print(f'cast call {args.router} "getAgentSession(bytes32)" {args.session_id} --rpc-url {args.rpc}')
        print(f'cast call {args.router} "isSessionActive(bytes32)" {args.session_id} --rpc-url {args.rpc}')
    elif args.action == "list":
        if not args.owner:
            raise ValueError("--owner is required for list")
        print("Listing owner agent sessions via cast:")
        print(f'cast call {args.router} "getOwnerSessions(address)" {args.owner} --rpc-url {args.rpc}')
    elif args.action == "revoke":
        if not args.session_id:
            raise ValueError("--session-id is required for revoke")
        print("Instant session revocation via cast:")
        print(f'cast send {args.router} "revokeAgentSession(bytes32)" {args.session_id} --rpc-url {args.rpc} --private-key $PRIVATE_KEY')
    elif args.action == "pay":
        if not args.session_id or args.invoice_id is None:
            raise ValueError("--session-id and --invoice-id are required for pay")
        print("Executing scoped agent direct payment via cast:")
        print(f'cast send {args.router} "payDirectWithSession(bytes32,uint256)" {args.session_id} {args.invoice_id} --rpc-url {args.rpc} --private-key $AGENT_PRIVATE_KEY')
    elif args.action == "fund-escrow":
        if not args.session_id or args.invoice_id is None:
            raise ValueError("--session-id and --invoice-id are required for fund-escrow")
        print("Executing scoped agent escrow funding via cast:")
        print(f'cast send {args.router} "fundEscrowWithSession(bytes32,uint256)" {args.session_id} {args.invoice_id} --rpc-url {args.rpc} --private-key $AGENT_PRIVATE_KEY')


def main():
    parser = argparse.ArgumentParser(description="AevumPay CLI for Aevum Testnet (Chain ID 44005)")
    parser.add_argument("--rpc", default=RPC_URL, help="Aevum Testnet RPC URL")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Check Aevum Testnet RPC and tUSD8 contract").set_defaults(func=cmd_status)

    p_bal = sub.add_parser("balance", help="Check tQDAY and tUSD8 balances for an address")
    p_bal.add_argument("address", help="0x EVM address")
    p_bal.set_defaults(func=cmd_balance)

    p_inv = sub.add_parser("invoice", help="Print cast command to inspect an invoice")
    p_inv.add_argument("router", help="Deployed AevumPayRouter address")
    p_inv.add_argument("invoice_id", type=int, help="Invoice ID")
    p_inv.set_defaults(func=cmd_invoice)

    p_sess = sub.add_parser("session", help="Print cast commands for AI agent session guardrails")
    p_sess.add_argument("action", choices=["inspect", "list", "revoke", "pay", "fund-escrow"], help="Session action")
    p_sess.add_argument("router", help="Deployed AevumPayRouter address")
    p_sess.add_argument("--session-id", help="bytes32 session ID")
    p_sess.add_argument("--owner", help="Owner 0x address (for list)")
    p_sess.add_argument("--invoice-id", type=int, help="Invoice ID (for pay / fund-escrow)")
    p_sess.set_defaults(func=cmd_session)

    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
