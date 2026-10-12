#!/usr/bin/env python3
"""
Re-price an EVM execution trace from the Cancun gas schedule (what revm / `cast run`
charges) to ROOTSTOCK's (what RSKj charges), and break the cost down.

Usage:
    cast run <tx> -r <rpc> --trace-printer > trace.txt
    reprice.py trace.txt --tx <tx> --rpc <rpc>

Rootstock's schedule, measured with eth_estimateGas on mainnet (RskJ 9.0.3, 2026-10-12):
  * SLOAD 200 flat (no EIP-2929 cold/warm, no EIP-1884)
  * SSTORE by CURRENT value (no EIP-2200 net metering): 0 -> non-zero 20,000, any other
    write 5,000 (a no-op write too); a non-zero -> 0 write refunds 15,000
  * refunds capped at gasUsed / 2 (receipts: RIF approve(x, 0) = 14,898 = half of ~29.8k)
  * CALL / STATICCALL / DELEGATECALL / CALLCODE 700, EXTCODESIZE / EXTCODECOPY 700,
    BALANCE / EXTCODEHASH 400, flat (no cold/warm)
  * calldata 16 / 4 per non-zero / zero byte (EIP-2028), intrinsic 21,000 (identical)
Everything else is charged the same, so it is carried over from the trace unchanged.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict

LINE = re.compile(r'depth:(\d+), PC:(\d+), gas:0x[0-9a-f]+\((\d+)\), OPCODE: "(\w+)"\((\d+)\)\s+refund:0x[0-9a-f]+\((\d+)\) Stack:\[(.*?)\]')
CALLS = {"CALL", "CALLCODE", "DELEGATECALL", "STATICCALL"}
ACCOUNT = {"BALANCE": 400, "EXTCODESIZE": 700, "EXTCODECOPY": 700, "EXTCODEHASH": 400}
PRECOMPILES = {i for i in range(1, 11)}


def rpc(url, method, params):
    out = subprocess.run(
        ["curl", "-s", url, "-H", "content-type: application/json", "-d", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)["result"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--tx", required=True)
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--gas-used", type=int, help="revm gasUsed reported by cast run")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    tx = rpc(a.rpc, "eth_getTransactionByHash", [a.tx])
    block = int(tx["blockNumber"], 16)
    pre = hex(block - 1)
    to = int(tx["to"], 16)
    sender = int(tx["from"], 16)
    data = bytes.fromhex(tx["input"][2:])
    calldata = sum(16 if b else 4 for b in data)

    steps = []
    for line in open(a.trace):
        m = LINE.search(line)
        if m:
            d, pc, gas, op, code, refund, stack = m.groups()
            st = [int(x) for x in stack.split(", ")] if stack.strip() else []
            steps.append((int(d), int(gas), op, int(refund), st))
    if not steps:
        sys.exit("no trace steps parsed")

    # Storage context per depth: tx.to at depth 1; a CALL/STATICCALL switches to its
    # target, DELEGATECALL/CALLCODE keep the caller's.
    ctx = {1: to}
    warm_addr = {to, sender} | PRECOMPILES
    warm_slot = set()
    current = {}  # (addr, slot) -> value as last written/read in this tx
    orig_cache = {}

    def original(addr, slot):
        k = (addr, slot)
        if k not in orig_cache:
            v = rpc(a.rpc, "eth_getStorageAt", ["0x%040x" % addr, hex(slot), pre])
            orig_cache[k] = int(v, 16)
        return orig_cache[k]

    delta = 0  # RSK minus Cancun, execution (pre-refund)
    rsk_refund = 0
    by = defaultdict(lambda: [0, 0, 0])  # op -> [count, cancun, rsk]
    sstore_kinds = defaultdict(int)
    pending_sload = None  # (addr, slot) whose value is the next step's stack top

    for i, (d, gas, op, refund, st) in enumerate(steps):
        if pending_sload is not None:
            # The SLOAD result is the top of the stack at the next step of the same frame.
            nxt = steps[i]
            if nxt[0] == pending_sload[2] and nxt[4]:
                current.setdefault(pending_sload[:2], nxt[4][-1])
            pending_sload = None
        addr = ctx.get(d, to)
        if op == "SLOAD":
            slot = st[-1]
            cold = (addr, slot) not in warm_slot
            warm_slot.add((addr, slot))
            c = 2100 if cold else 100
            delta += 200 - c
            by["SLOAD"][0] += 1; by["SLOAD"][1] += c; by["SLOAD"][2] += 200
            if (addr, slot) not in current:
                pending_sload = (addr, slot, d)
        elif op == "SSTORE":
            slot, new = st[-1], st[-2]
            k = (addr, slot)
            orig = original(addr, slot)
            cur = current.get(k, orig)
            cold = k not in warm_slot
            warm_slot.add(k)
            # Cancun (EIP-2200 + 2929): the dynamic part
            if new == cur:
                c = 100
            elif orig == cur:
                c = 20000 if orig == 0 else 2900
            else:
                c = 100
            c += 2100 if cold else 0
            # Rootstock: by current value only
            r = 20000 if (cur == 0 and new != 0) else 5000
            if cur != 0 and new == 0:
                rsk_refund += 15000
            kind = "0->x" if cur == 0 and new != 0 else "x->0" if cur != 0 and new == 0 else "x->y" if cur != new else "noop"
            sstore_kinds[kind] += 1
            delta += r - c
            by["SSTORE"][0] += 1; by["SSTORE"][1] += c; by["SSTORE"][2] += r
            current[k] = new
        elif op in CALLS:
            target = st[-2]
            cold = target not in warm_addr
            warm_addr.add(target)
            c = 2600 if cold else 100
            delta += 700 - c
            by[op][0] += 1; by[op][1] += c; by[op][2] += 700
            ctx[d + 1] = addr if op in ("DELEGATECALL", "CALLCODE") else target
        elif op in ACCOUNT:
            target = st[-1]
            cold = target not in warm_addr
            warm_addr.add(target)
            c = 2600 if cold else 100
            delta += ACCOUNT[op] - c
            by[op][0] += 1; by[op][1] += c; by[op][2] += ACCOUNT[op]

    cancun_refund = steps[-1][3]
    gas_used = a.gas_used
    # Cancun gross execution = gasUsed + the refund it applied (cap gross/5).
    gross_cancun = gas_used + cancun_refund if gas_used is not None else None
    if gross_cancun is not None and cancun_refund > gross_cancun // 5:
        gross_cancun = gas_used * 5 // 4  # cap was binding: used = 4/5 gross
    gross_rsk = gross_cancun + delta
    applied = min(rsk_refund, gross_rsk // 2)
    rsk_used = gross_rsk - applied
    receipt = rpc(a.rpc, "eth_getTransactionReceipt", [a.tx])
    actual = int(receipt["gasUsed"], 16)
    res = {
        "tx": a.tx,
        "calldata_gas": calldata,
        "cancun_gas_used": gas_used,
        "cancun_refund": cancun_refund,
        "rsk_gross": gross_rsk,
        "rsk_refund": applied,
        "rsk_gas_used_sim": rsk_used,
        "rsk_gas_used_actual": actual,
        "error_pct": round((rsk_used / actual - 1) * 100, 2),
        "sstores": dict(sstore_kinds),
        "by_op": {k: {"n": v[0], "cancun": v[1], "rsk": v[2]} for k, v in by.items()},
    }
    print(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
