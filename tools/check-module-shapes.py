#!/usr/bin/env python3
"""Module-seam invariants that are otherwise only prose.

Three properties, all syntactic, all previously asserted in file headers and
enforced nowhere — which is the §F23 failure mode this file exists to avoid.

  1. A taker grant must be unambiguous about which dispatch it authorises.
  2. Every `makeOnBehalf` must pin its dispatcher.
  3. Every entrypoint that spends the module's OWN balance must pin its caller.
  4. A PULL `makeOnBehalf` blob must not be readable as a pre-fund descriptor.

────────────────────────────────────────────────────────────────────────────────
(1) A taker grant must be unambiguous about which dispatch it authorises.

`Permit3`'s taker book is keyed by `(user, spender, module, keccak256(data))` and
knows nothing about WHICH dispatch the module implements. `take` calls
`ITakerModule.takeOnBehalf`; `takeFor` calls `ITakerForModule.takeForOnBehalf`.
A contract implementing BOTH would let a single `approveTaker` authorise either
shape, with nothing in the grant telling the maker which one they signed up for —
and the composite shape moves the maker's own funds on the value-IN leg.

This used to be enforced as "one module, one shape". That is stricter than the
property actually needed, and it forced a separate deployment per shape per venue.
The property needed is only that NO `data` blob can be accepted by both
entrypoints — because then no `ref` can ever be valid for both, and the grant is
unambiguous again.

The two data spaces are already disjoint at word 0, so the property is cheap to
establish: a pre-fund blob sets bits 255 and 253 (`>> 253 == 5`), while a plain-take
blob opens with an address, a `MarketParams` head or a `uint8` op, all below
`2^160` (`>> 253 == 0`). A merged contract asserts its own half in each entrypoint
— `PreFundGuard.requireLegRef` in `takeForOnBehalf`, `PreFundGuard.requirePlainTake` in
`takeOnBehalf`.

So a contract MAY now implement both, but ONLY with both guards present. That is
what this script checks. The invariant changed shape; it did not become prose —
which is the §F23 failure mode this file exists to avoid.

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
# The two halves of the disjointness proof, one per entrypoint.
GUARD_FOR = re.compile(r"PreFundGuard\.(?:requireLegRef|requireFundingDescriptor)\s*\(")
GUARD_TAKE = re.compile(r"PreFundGuard\.requirePlainTake\s*\(")

# ── (2) and (3): the caller pin, per seam ────────────────────────────────────
#
# MAKE is dispatched Settlement → module DIRECTLY, so its pin is `msg.sender` and
# the EVM asserts it. TAKE/TAKE_FOR arrive through Permit3, so `msg.sender` is the
# HUB and the principal has to cross it as data — the forwarded `spender`. The two
# are the same predicate ("the dispatcher is Settlement") with different vehicles,
# and both are load-bearing the moment a module spends value it holds itself.
MAKE_FN = re.compile(r"\bfunction\s+makeOnBehalf\s*\(")
# `_gatePreFundMake` folds the pin and the descriptor check together.
# ⚠ THE SPELLINGS ARE PLURAL, and a pattern that knows only one is worse than no
#   pattern: it reports seven clean modules and trains you to skip the output. The
#   pin is written as a bare `msg.sender` compare (against `settlement`,
#   `SETTLEMENT` or `_settlement`), as an `onlySettlement` modifier, or folded into
#   `_gatePreFundMake` / `PreFundGuard.requireSettlement`. All four are the same
#   assertion; only the vehicle differs.
PIN_MAKE = re.compile(
    r"_gatePreFundMake\s*\(|"
    r"PreFundGuard\.requireSettlement\s*\(\s*msg\.sender|"
    r"msg\.sender\s*!=\s*(?:address\(\s*)?_?[sS][eE][tT][tT][lL][eE][mM][eE][nN][tT]|"
    r"\bonlySettlement\b"
)
# `_gatePreFund` folds the hub pin, the spender pin and the descriptor check.
PIN_FOR = re.compile(r"_gatePreFund\s*\(|PreFundGuard\.requireSettlement\s*\(\s*spender")
# Spending from the module's own balance. `requireDelivered`/`floorOf` ARE the
# balance floor, so their presence is exactly the "this is pre-funded" signal.
PRE_FUNDED = re.compile(
    # The helper form...
    r"PreFundGuard\.(?:requireDelivered|floorOf)\s*\("
    # ...OR a HAND-ROLLED floor. Detecting only the helper meant a module that wrote
    # `IERC20(asset).balanceOf(address(this)) - forAmount` itself was classified
    # PULL-shaped, and the `spender == settlement` pin silently became optional —
    # which is the exact F27/C-1 shape this file exists to prevent.
    r"|balanceOf\s*\(\s*address\(this\)\s*\)\s*-\s*\w*[fF]or\w*"
)

# ── (4) the MAKE data space must stay disjoint ───────────────────────────────
#
# {Base._runItem} decides whether a MAKE item is pre-funded by reading word 0 of
# `item.data` and testing `>> 253 == 5`. That is safe ONLY while an ordinary pull
# blob cannot reach that value — the same disjointness argument
# `PreFundGuard.requirePlainTake` makes on the taker seam, except here the CORE
# does the classifying, so no module-side guard can rescue a collision.
#
# A blob opening with an `address` is structurally below 2^160 and can never
# collide. A blob opening with a `bytes32` — a market id, a hash — collides with
# probability 1/8, and the failure is silent at the type level: the settler would
# size the item from `_forSlice` instead of `item.amount`. It fails closed in
# practice (a random low-16-bits leg index almost certainly reverts
# `ForLegMissing`), so the realistic damage is a permanently unfillable order
# shape rather than a theft — but "almost certainly" is not an invariant.
#
# Anything whose first decoded field is not an `address` therefore has to be
# justified HERE, once, in writing. Add a row when you add such a module.
FIRST_FIELD = re.compile(r"abi\.decode\(\s*data(?:\[[^\]]*\])?\s*,\s*\(([^)]*)\)")
WORD0_EXEMPT = {
    # struct is DYNAMIC (contains a `bytes`/array member), so word 0 is an ABI
    # offset — a small number, never near 2^255.
    "AcrossBridgeOutModule": "AcrossSpec is dynamic (bytes message) -> word 0 is an offset",
    "LzOftBridgeOutModule": "LzSpec is dynamic (bytes extraOptions) -> word 0 is an offset",
    "PermissionlessCallModule": "CallSpec is dynamic (bytes callData) -> word 0 is an offset",
    "MidnightSupplyCollateralModule": "Market is dynamic (CollateralParams[]) -> word 0 is an offset",
    "MidnightRepayModule": "Market is dynamic (CollateralParams[]) -> word 0 is an offset",
    "MidnightLendModule": "Offer embeds the dynamic Market -> word 0 is an offset",
    # struct is STATIC, and its first field is an address.
    "CctpBridgeOutModule": "CctpSpec is static, first field `address inputToken`",
    "FunnelGrantModule": "GrantSpec is static, first field `address spender`",
    "MorphoBlueSupplyCollateralModule": "MarketParams is static, first field `address loanToken`",
    "MorphoBlueSupplyModule": "MarketParams is static, first field `address loanToken`",
    "MorphoBlueRepayModule": "MarketParams is static, first field `address loanToken`",
    # a small-bounded integer, orders of magnitude below 5 * 2^253.
    "LiquityV2AddCollModule": "word 0 is `branchIndex`, a small collateral-branch ordinal",
    "LiquityV2RepayModule": "word 0 is `branchIndex`, a small collateral-branch ordinal",
}
# `contract X is A, B {` — the name plus its inheritance list, up to the brace.
CONTRACT = re.compile(r"\bcontract\s+(\w+)\s*(?:is\s+([^{]*))?\{")


def function_body(body: str, fname: str) -> str:
    """The body of `fname` within a contract body, brace-matched.

    ⚠ GRANULARITY IS THE POINT. Every check below used to run `.search(body)` over
    the WHOLE contract, so a contract with several entrypoints passed if ANY ONE of
    them carried the guard — a module with a guarded `takeForOnBehalf` and an
    unguarded second entrypoint was reported clean. The CALLER PIN and the DATA-SPACE
    guards are per-entrypoint obligations and are now checked per entrypoint.

    (The balance FLOOR deliberately stays contract-wide: it legitimately lives in a
    private helper the entrypoint calls, e.g. `_supply` / `_repayAndSweep`.)
    """
    m = re.search(r"\bfunction\s+" + re.escape(fname) + r"\s*\(", body)
    if not m:
        return ""
    i = body.find("{", m.end())
    if i == -1:
        return ""
    depth = 0
    for k in range(i, len(body)):
        if body[k] == "{":
            depth += 1
        elif body[k] == "}":
            depth -= 1
            if depth == 0:
                # From the `function` keyword, NOT the opening brace: the caller pin is
                # often a MODIFIER (`onlySettlement`), which lives in the signature.
                # Slicing from the brace made the three bridge out-modules look
                # unpinned when they are pinned exactly as intended.
                return body[m.start() : k + 1]
    return ""


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
    unpinned_make = []
    unpinned_prefund = []
    word0 = []
    scanned = 0
    makes = 0
    dual = 0
    # ⚠ THREE globs, and the third was a COVERAGE HOLE: `packages/modules/bridge/src`
    #   is two levels deep, so it matched neither of the original two and every bridge
    #   module went unscanned. A check with unknown coverage is worse than none.
    for path in (
        sorted(ROOT.glob("packages/*/src/**/*.sol"))
        + sorted(ROOT.glob("packages/*/*/src/**/*.sol"))
        + sorted(ROOT.glob("packages/*/*/*/src/**/*.sol"))
    ):
        try:
            src = path.read_text(encoding="utf-8")
        except OSError:
            continue
        # An interface may of course declare either; only concrete contracts can
        # be the thing a maker points an `approveTaker` at.
        if (
            "takeForOnBehalf" not in src
            and "takeOnBehalf" not in src
            and "makeOnBehalf" not in src
        ):
            continue
        for name, inherits, body in contract_spans(src):
            # ── (2) every `makeOnBehalf` pins its dispatcher ──
            #
            # A maker module acts on a position under the maker's signature alone.
            # Settlement is its only legitimate caller, and on this seam that is one
            # comparison against `msg.sender` — no parameter, nothing to forget to
            # compare. Cheap to write, cheap to check, and the check is what keeps it
            # from being 40-odd independent chances to omit it.
            if MAKE_FN.search(body):
                makes += 1
                make_body = function_body(body, "makeOnBehalf")
                if not PIN_MAKE.search(make_body):
                    unpinned_make.append((path.relative_to(ROOT), name))
                # ── (3) a PRE-FUNDED make also pins the descriptor ──
                # The core sizes `forAmount` from the descriptor; a module that
                # funds from balance against a number the core did NOT size that
                # way is the F27/C-4 shape.
                if "_gatePreFundMake(" not in make_body:
                    # ── (4) a PULL make must not be readable as a pre-fund blob ──
                    m = FIRST_FIELD.search(body)
                    first = m.group(1).split(",")[0].strip() if m else "address"
                    if first != "address" and name not in WORD0_EXEMPT:
                        word0.append((path.relative_to(ROOT), name, first))
                if PRE_FUNDED.search(body) and "_gatePreFundMake(" not in make_body:
                    unpinned_prefund.append(
                        (path.relative_to(ROOT), name, "makeOnBehalf funds from balance without _gatePreFundMake")
                    )
            # ── (3) a PRE-FUNDED takeFor pins the forwarded spender ──
            #
            # `Permit3.takeFor` is PERMISSIONLESS and `approveTaker` lets a caller
            # name ITSELF spender, so without this one self-granted unit of taker
            # allowance moves the singleton's whole balance — F27/C-1, which was
            # live and PoC'd. The pull shape does not need it (the value comes out
            # of the user's own wallet), which is exactly why it must be checked
            # rather than assumed: the two shapes look identical at this seam.
            take_for_body = function_body(body, "takeForOnBehalf")
            if TAKE_FOR.search(body) and PRE_FUNDED.search(body) and not PIN_FOR.search(take_for_body):
                unpinned_prefund.append(
                    (path.relative_to(ROOT), name, "takeForOnBehalf funds from balance without a spender pin")
                )

            if not (TAKE.search(body) or TAKE_FOR.search(body)):
                continue
            scanned += 1
            both_fns = bool(TAKE.search(body) and TAKE_FOR.search(body))
            both_ifaces = "ITakerModule" in inherits and "ITakerForModule" in inherits
            if not (both_fns or both_ifaces):
                continue
            # Dual-shape is allowed, but only when each entrypoint pins its own half
            # of the data space so the two can never collide on `ref`.
            missing = []
            if not GUARD_FOR.search(take_for_body):
                missing.append("PreFundGuard.requireLegRef or requireFundingDescriptor in takeForOnBehalf")
            if not GUARD_TAKE.search(function_body(body, "takeOnBehalf")):
                missing.append("PreFundGuard.requirePlainTake in takeOnBehalf")
            if missing:
                offenders.append((path.relative_to(ROOT), name, missing))
            else:
                dual += 1

    if unpinned_make:
        print(f"{len(unpinned_make)} maker module(s) do NOT pin their dispatcher:\n", file=sys.stderr)
        for rel, name in unpinned_make:
            print(f"  {rel}: contract {name}", file=sys.stderr)
        print(
            "\n`makeOnBehalf` is dispatched by Settlement DIRECTLY, so the caller pin is\n"
            "`msg.sender == settlement` — one comparison, asserted by the EVM. Without it\n"
            "anyone can drive the module against any position the maker has approved it for.",
            file=sys.stderr,
        )
        return 1

    if unpinned_prefund:
        print(f"{len(unpinned_prefund)} pre-funded entrypoint(s) are UNPINNED:\n", file=sys.stderr)
        for rel, name, why in unpinned_prefund:
            print(f"  {rel}: contract {name}\n      {why}", file=sys.stderr)
        print(
            "\nA module that spends its OWN balance is only as safe as the number it is\n"
            "handed and the caller that hands it over. On MAKE that is `_gatePreFundMake`;\n"
            "on TAKE_FOR it is `_gatePreFund` / requireSettlement(spender, ...), because\n"
            "`Permit3.takeFor` is permissionless and `approveTaker` lets a caller name\n"
            "itself spender (F27/C-1).",
            file=sys.stderr,
        )
        return 1

    if word0:
        print(f"{len(word0)} pull-MAKE module(s) may collide with the pre-fund data space:\n", file=sys.stderr)
        for rel, name, first in word0:
            print(f"  {rel}: contract {name}\n      `data` word 0 decodes as `{first}`, not `address`", file=sys.stderr)
        print(
            "\n`Base._runItem` classifies a MAKE item as PRE-FUNDED by testing word 0 of\n"
            "`item.data` for `>> 253 == 5`. An `address` is structurally below 2^160 and can\n"
            "never reach it; a `bytes32` id or hash reaches it 1 time in 8, and the settler\n"
            "then sizes the item from the funding descriptor instead of from `item.amount`.\n"
            "Either open the blob with an address / a dynamic struct, or add the contract to\n"
            "WORD0_EXEMPT with the reason its word 0 is bounded.",
            file=sys.stderr,
        )
        return 1

    if offenders:
        print(f"{len(offenders)} contract(s) implement BOTH taker shapes UNGUARDED:\n", file=sys.stderr)
        for rel, name, missing in offenders:
            print(f"  {rel}: contract {name}", file=sys.stderr)
            for m in missing:
                print(f"      missing {m}", file=sys.stderr)
        print(
            "\nThe taker book keys on (user, spender, module, ref) and cannot tell the two\n"
            "dispatches apart, so one approveTaker would authorise either. A dual-shape\n"
            "contract must make the two data spaces disjoint at word 0: add the guards\n"
            "above, or split the contract.",
            file=sys.stderr,
        )
        return 1

    note = f"; {dual} dual-shape, each with both data-space guards" if dual else ""
    print(f"{scanned} taker contract(s) scanned{note}")
    print(f"{makes} maker contract(s) scanned; all pin their dispatcher")
    return 0


if __name__ == "__main__":
    sys.exit(main())
