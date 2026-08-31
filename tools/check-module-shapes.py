#!/usr/bin/env python3
"""One module, one taker shape — enforced, not documented.

`Permit3`'s taker book is keyed by `(user, spender, module, keccak256(data))` and
knows nothing about WHICH dispatch the module implements. `take` calls
`ITakerModule.takeOnBehalf`; `takeFor` calls `ITakerForModule.takeForOnBehalf`.
A contract implementing BOTH would let a single `approveTaker` authorise either
shape, with nothing in the grant telling the maker which one they signed up for —
and the composite shape moves the maker's own funds on the value-IN leg.

Every module shipped implements exactly one. That was a convention living in
`ITakerForModule`'s prose, which is the failure mode §F23 exists to record: a rule
that holds only because every current integrator happens to follow it. This is the
enforcement point.

Runs over SOURCE rather than artifacts on purpose. A full-tree `forge build` does
not currently succeed (one bridge module is stack-too-deep under the default
profile), so an ABI scan would silently cover a subset — and a check with unknown
coverage is worse than none. Source is complete and the pattern it has to catch is
syntactic: a contract cannot implement `takeForOnBehalf` without writing it down.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TAKE = re.compile(r"\bfunction\s+takeOnBehalf\s*\(")
TAKE_FOR = re.compile(r"\bfunction\s+takeForOnBehalf\s*\(")
# `contract X is A, B {` — the name plus its inheritance list, up to the brace.
CONTRACT = re.compile(r"\bcontract\s+(\w+)\s*(?:is\s+([^{]*))?\{")


def contract_spans(src: str):
    """(name, body) for each contract, sliced by brace depth."""
    for m in CONTRACT.finditer(src):
        start = m.end() - 1
        depth = 0
        for i in range(start, len(src)):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    yield m.group(1), m.group(2) or "", src[start : i + 1]
                    break


def main() -> int:
    offenders = []
    scanned = 0
    for path in sorted(ROOT.glob("packages/*/src/**/*.sol")) + sorted(ROOT.glob("packages/*/*/*/src/**/*.sol")):
        try:
            src = path.read_text(encoding="utf-8")
        except OSError:
            continue
        # An interface may of course declare either; only concrete contracts can
        # be the thing a maker points an `approveTaker` at.
        if "takeForOnBehalf" not in src and "takeOnBehalf" not in src:
            continue
        for name, inherits, body in contract_spans(src):
            scanned += 1
            both_fns = TAKE.search(body) and TAKE_FOR.search(body)
            both_ifaces = "ITakerModule" in inherits and "ITakerForModule" in inherits
            if both_fns or both_ifaces:
                offenders.append((path.relative_to(ROOT), name))

    if offenders:
        print(f"{len(offenders)} contract(s) implement BOTH taker shapes:\n", file=sys.stderr)
        for rel, name in offenders:
            print(f"  {rel}: contract {name}", file=sys.stderr)
        print(
            "\nThe taker book keys on (user, spender, module, ref) and cannot tell the two\n"
            "apart, so one approveTaker would authorise either dispatch. Split the contract.",
            file=sys.stderr,
        )
        return 1

    print(f"{scanned} taker contract(s) scanned; each implements exactly one shape")
    return 0


if __name__ == "__main__":
    sys.exit(main())
