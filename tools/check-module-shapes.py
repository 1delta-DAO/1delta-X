#!/usr/bin/env python3
"""Module-seam invariants that are otherwise only prose.

Six properties, all syntactic, all previously asserted in file headers and
enforced nowhere — which is the §F23 failure mode this file exists to avoid.

  1. A taker grant must be unambiguous about which dispatch it authorises.
  2. Every `makeOnBehalf` must pin its dispatcher.
  3. Every entrypoint that spends the module's OWN balance must pin its caller.
  4. A PULL `makeOnBehalf` blob must not be readable as a pre-fund descriptor.
  5. A data-derived Permit3 pull amount is width-checked, not truncated (I-5).
  6. A venue value-IN call is never handed a max sentinel (I-15).
  7. A multi-op module rejects an op it does not implement.
  8. A module never pays out a RAW self-balance — every `balanceOf(address(this))`
     is a floor or a delta.

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
# The spender pin on the TAKE_FOR seam. (`_gatePreFund`, which folded it with the
# hub pin and a leg-ref check, was removed 2026-09-11 — every pre-fund takeFor is
# dual-shape now and writes the three checks inline.)
PIN_FOR = re.compile(r"PreFundGuard\.requireSettlement\s*\(\s*spender")
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

# ── (5) a data-derived pull amount must be width-checked, not truncated ──────
#
# Permit3's token book is `uint160`. A module pulls with
# `permit3.transferFrom(user, to, token, uint160(X))`. When `X` is the core-sized
# slice (`amount`) or the core-sized funding leg (`forAmount`), it is already
# proven `<= type(uint160).max` by {Base._runItem}, so the cast is a no-op and safe.
#
# When `X` is DERIVED FROM ORDER DATA — a ratio (`ceil(amount*collateralTotal/
# borrowTotal)`), a repay clamp against a signed `sideAmount`, anything the maker
# put in the blob — it can exceed `2^160`, and then `uint160(X)` SILENTLY WRAPS.
# The paired `forceApprove(token, venue, X)` uses the FULL `uint256`, so the module
# pulls `X mod 2^160` (e.g. 1 wei) while approving `X` (e.g. ~1.46e48) to an
# order-decoded, attacker-choosable venue — the F-2 drain. The fix is
# `Narrow160.to160(X)`, which REVERTS on overflow instead of wrapping.
#
# So: every `uint160(...)` feeding a `transferFrom` amount must be either `amount`,
# `forAmount`, or justified HERE as bounded. `Narrow160.to160(...)` is not matched —
# it is the safe form. Add a row when you add a data-derived pull, with the reason
# it cannot exceed `2^160` (or route it through Narrow160 and add nothing).
PULL_NARROW = re.compile(r"transferFrom\s*\([^;]*?\buint160\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)\s*\)")
NARROW_SAFE_EXPR = {"amount", "forAmount"}  # core-sized, proven <= 2^160 by Base._runItem
NARROW_EXEMPT = {
    # `toPull = recycle ? amount : min(amount, debt)` — both arms <= `amount`, the
    # core slice, so <= 2^160. The recycle/repay modules across every venue.
    ("SiloRepayModule", "toPull"): "toPull <= amount (core slice)",
    ("VenusRepayModule", "toPull"): "toPull <= amount (core slice)",
    ("ExactlyRepayModule", "toPull"): "toPull <= amount (core slice)",
    ("EulerV2RepayModule", "toPull"): "toPull <= amount (core slice)",
    ("AaveV2RepayModule", "toPull"): "toPull <= amount (core slice)",
    ("AaveV3RepayModule", "toPull"): "toPull <= amount (core slice)",
    ("AaveV4RepayModule", "toPull"): "toPull <= amount (core slice)",
    ("CompoundV2RepayModule", "toPull"): "toPull <= amount (core slice)",
    ("CometRepayModule", "toPull"): "toPull <= amount (core slice)",
    ("DolomiteOperatorModule", "toPull"): "toPull <= amount (core slice)",
    # `toRepay = min(amount, debt)` — the amount-bounded clamp (SAFE), as opposed to
    # the `min(sideAmount, debt)` form that WAS the F-2 bug and now uses Narrow160.
    ("RiverRepayModule", "toRepay"): "toRepay = min(amount, debt) <= amount",
    ("MidnightRepayModule", "toRepay"): "toRepay = min(amount, debt) <= amount",
    ("LiquityV2RepayModule", "toRepay"): "toRepay = min(amount, entireDebt) <= amount",
    ("CompoundV2NativeRepayModule", "toRepay"): "toRepay = min(amount, debt) <= amount",
    # Full-mode cToken/aToken balance pulls: an under-pull redeems LESS and reverts at
    # NOTE (2026-09-10): these reasons used to cite `require(received >= amount)`,
    # which was deleted in the 2026-09 gate strip and then RESTORED only on `Full`
    # legs as `FullFillGuard.requireDelivered`. compound-v2 has no `positionOf` and
    # so no sweep-shaped Full branch, so the live justification is the narrower one:
    # there is no paired `forceApprove` to widen, so a truncating cast under-pulls
    # and the venue call reverts on insufficient cTokens. Fails closed either way.
    ("CompoundV2WithdrawModule", "cBal"): "Full-mode balance; under-pull reverts in the venue on insufficient cTokens, no paired approve",
    ("CompoundV2NativeWithdrawModule", "cBal"): "Full-mode balance; under-pull reverts in the venue on insufficient cTokens, no paired approve",
    # Exact-mode ceiling cAmount: an under-pull makes `redeemUnderlying(amount)`
    # revert on insufficient cTokens; no paired approve.
    ("CompoundV2WithdrawModule", "cAmount"): "Exact-mode ceiling; under-pull reverts redeemUnderlying(amount), no paired approve",
    ("CompoundV2NativeWithdrawModule", "cAmount"): "Exact-mode ceiling; under-pull reverts redeemUnderlying(amount), no paired approve",
    # `fromMaker = amount - fromSelf`, fromSelf <= amount, so fromMaker <= amount.
    ("RiverProceeds", "fromMaker"): "fromMaker = amount - fromSelf <= amount (library; core slice)",
    # explicit `if (pull > type(uint160).max) revert AmountOverflow()` precedes the
    # cast — the Narrow160 semantics, inlined.
    ("ProportionalSweepModule", "pull"): "guarded by an inline `> type(uint160).max` revert",
    # `bal` is the user's aToken balance; truncation UNDER-pulls and fails closed at
    # `require(received >= amount)`, and there is no paired approve to widen.
    # Morpho repay callback: `assets` is Morpho's own repay accounting, `morpho` is
    # an IMMUTABLE (not order-decoded), so the paired approve cannot reach a hostile
    # venue and there is nothing to amplify.
    ("MorphoBlueRepayModule", "assets"): "morpho is immutable, not order-decoded; assets is Morpho's accounting",
}

# ── (7) a multi-op module rejects an unknown op ──────────────────────────────
#
# Several ops may share one contract — and several ops SHOULD share one contract
# whenever they consume the same standing grant, because that grant is what a
# maker actually has to hand over and revoke. `AaveV3CreditModule` holds Aave's
# credit delegation for both the bare borrow and the fused leverage op precisely
# so a maker delegates their credit line once.
#
# That merge is safe for exactly one reason: the op lives INSIDE `data`, so it is
# inside `ref = keccak256(data)`, and Permit3's taker book keys on `ref`. A grant
# signed for one op therefore cannot be replayed as another.
#
# THE PROPERTY THAT ARGUMENT DEPENDS ON, and the one this rule pins: an op the
# module does not implement must REVERT. A dispatcher written as
#
#     if (op == A) { ... } else { ...B... }          // ← no reject branch
#
# silently maps every unknown op onto B. The grant was then signed for a `data`
# blob naming an op that does not exist, and the module runs a DIFFERENT op with
# it — the exact substitution the `ref` keying is supposed to make impossible. The
# omission is invisible at the type level (an `enum` does not constrain a
# `uint256` decoded from calldata) and costs one line to prevent.
#
# The test is syntactic and deliberately loose: a contract that declares an op
# enum or reads an op discriminator must also contain a `revert` naming an op
# error. It cannot prove the branch is reachable — that is what
# `test_*_revertsOnUnknownOp` is for — but it does catch the whole-branch
# omission, which is the failure that actually happens.
# Call sites only — `(?<!function )` — so the abstract base that DECLARES
# `_preFundOp` is not mistaken for a dispatcher that reads it.
OP_DISPATCH = re.compile(r"\benum\s+Op\s*\{|(?<!function )_preFundOp\s*\(|(?<!function )_plainOp\s*\(")
OP_REJECT = re.compile(r"\brevert\s+(?:\w+\.)?(?:BadOp|UnknownOp|InvalidOp|UnsupportedOp)\s*\(")


# ── (8) a module never pays out a raw self-balance ───────────────────────────
#
# THE INVARIANT THE MODULE-LEVEL REENTRANCY GUARDS WERE STANDING IN FOR, made explicit
# so the guards can go.
#
# Every module entrypoint is reached through a locked dispatcher — Settlement for
# MAKE, Permit3.take / takeFor for the taker seams — with ONE window Permit3 leaves
# open on purpose ({AllowanceTransfer.transferFrom} is "DELIBERATELY NOT
# nonReentrant"): a MAKE pull hands control to a maker-chosen token, and a hook
# can reach `Permit3.take` from inside it. It can only land `takeOnBehalf(X, …)`
# for an X that granted the HOOK CONTRACT a taker bucket — i.e. the attacker
# themselves (core `test_reentrancy_transferFrom_cannotReachTheSpendersBucket`).
# So the question is only ever: can an interleaved call, on ITS OWN account, on
# the SAME module balance, disturb what the in-flight fill measures?
#
# It cannot, as long as every payout is a same-call delta: `bal - floor`,
# `received - snapshot`, `min(received, amount)`. Nothing is ever paid from a
# balance read alone, so an interleaving that adds to or removes from the shared
# balance changes nothing the victim's fill pays out (dolomite
# `test_hookReentersTakeMidRepay_victimAccountingUnchanged_attackerMovesOnlyOwnFunds`
# runs exactly that interleaving with the guard removed). A census on 2026-09-11
# found all 77 self-balance reads in the tree already delta-measured.
#
# This rule pins it: a local assigned from `balanceOf(address(this))` must appear
# in a subtraction or comparison afterwards, and must NEVER be the amount argument
# of a transfer. A module that breaks it is exactly a module that would need a
# reentrancy guard back — and, more to the point, one that pays another fill's
# residue to whoever calls next (H-3, F-3).
SELF_BAL = re.compile(r"(\w+)\s*=\s*IERC20\(\w+\)\.balanceOf\(address\(this\)\)\s*;")
# also the direct form: `IERC20(t).balanceOf(address(this))` as a transfer amount
SELF_BAL_RAW_PAY = re.compile(
    r"(?:safeTransfer(?:From)?|\.transfer)\([^;]*?,\s*IERC20\(\w+\)\.balanceOf\(address\(this\)\)\s*\)"
)


# ── (6) a venue value-IN call is never handed a max sentinel (I-15) ──────────
#
# The repay mirror of I-10. I-10 forbids a max sentinel on the value-OUT side
# because a venue max burns whatever the MODULE holds; the value-IN side has the
# same defect with the sign flipped, and it is the more dangerous half because it
# reads as a convenience.
#
# The test is WHICH ACTOR the venue resolves the sentinel against:
#
#   • Against `onBehalfOf`'s DEBT — aave's `repay(asset, max, ...)`, euler's
#     `repay(max, account)`, compound v2's `repayBorrowBehalf(user, -1)`. These
#     compute exactly what our own clamp computes, so they are merely redundant.
#   • Against the CALLER'S BALANCE — comet's `supplyTo(dst, asset, max)` resolves
#     `max` to the MODULE's balance of `asset` and `doTransferIn`s it. On a shared
#     singleton that is "supply everything this contract is holding, including
#     another order's residue, into this order's position". Same shape as F-3,
#     opposite direction.
#
# The two are indistinguishable at the call site, and the second is a silent
# cross-order fund transfer rather than a revert. So the rule is flat: a venue
# amount argument is a clamped local (`toRepay`, `min(amount, debt)`) or a
# core-sized one (`amount` / `forAmount`) — never a sentinel. "Repay everything"
# uses a DEDICATED venue entrypoint that names the actor itself and takes no
# amount (lista's `repayAll(onBehalfOf)`, teller's `repayLoanFull(bidId)`,
# fluid's `operate(nftId, ..)` where the position is the actor), which cannot be
# resolved against the module by construction.
#
# Adding a row here is a decision that the venue resolves against the USER, with
# the reason written down — not a way to silence the check.
#
# COVERAGE LIMIT, stated so it is not mistaken for a proof: this reads the CALL
# SITE only. A sentinel laundered through a helper is invisible to it — fluid's
# `operate(nftId, ..., _negDelta(p.sideAmount), ...)` hides `type(int256).min`
# inside `_negDelta`, and does not fire. That one is safe for the reason above
# (Fluid resolves it against the position NFT named in the same call, never
# against the caller's balance; pinned by `fluid/test/integration/FluidFullClose.t.sol`),
# but the check did not establish that — a reviewer did. Treat a clean run as
# "no sentinel is written at a venue call site", not "no sentinel reaches a venue".
VALUE_IN_CALL = re.compile(
    r"\.\s*(repay|repayBorrow|repayBorrowBehalf|repayOnBehalfOf|repayDebt|repayBold|"
    r"repayAtMaturity|repayLoan|supplyTo|supply|payback|decreaseDebt|mint)\s*\(",
)
SENTINEL = re.compile(
    r"type\s*\(\s*u?int\d+\s*\)\s*\.\s*(?:max|min)"  # type(uint256).max / type(int256).min
    r"|\buint\d*\s*\(\s*-\s*1\s*\)"                     # uint256(-1)
    r"|\b0x[fF]{40,}\b"                                      # 0xffff… (aave's literal form)
    r"|\b[A-Z_]*_ALL\b"                                      # REPAY_ALL / FLUID_ALL constants
)
# Empty on purpose: every venue call in the tree passes a clamped or core-sized
# amount today, so there is nothing to exempt. Rows go here only when a venue's
# sentinel is proven to resolve against `onBehalfOf`, with that proof written out.
REPAY_SENTINEL_EXEMPT: dict[tuple[str, str], str] = {}


def arg_span(body: str, open_paren: int) -> str:
    """The text between a call's parens, balanced, so multi-line args are covered."""
    depth = 0
    for i in range(open_paren, len(body)):
        if body[i] == "(":
            depth += 1
        elif body[i] == ")":
            depth -= 1
            if depth == 0:
                return body[open_paren + 1 : i]
    return ""


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
# Anything whose first decoded field is not provably bounded therefore has to be
# justified HERE, once, in writing. Add a row when you add such a module.
# ⚠ NO SLICE. This rule is about WORD 0 of `item.data`, so only a decode of the
# WHOLE blob can answer it: `abi.decode(data[64:], (uint256, …))` is a TAIL read —
# every repay module in the tree does one — and its first field says nothing about
# word 0. Matching sliced decodes reported `AaveV2RepayModule` and
# `AaveV3RepayModule` as colliding on a `uint256` that is their `rateMode`.
FIRST_FIELD = re.compile(r"abi\.decode\(\s*data\s*,\s*\(([^)]*)\)")
# First-field types that CANNOT reach `>> 253 == 5`, by their own width:
#   `address`  < 2^160, the original case;
#   `uint8`    <= 255 — and it is the shape a merged-by-grant module opens with,
#              because its leading word is an OP discriminator. That is strictly
#              safer than an address, not a special case being waved through.
SAFE_FIRST_FIELD = {"address", "uint8", "uint16", "bool"}
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
# ⚠ LIBRARIES TOO. This matched `contract` only, so a `library` living beside the
#   modules — `RiverProceeds`, whose `settle` does a Permit3 pull sized from a
#   computed amount — was never scanned by rules 5/6/8, while a NARROW_EXEMPT row
#   keyed to a contract that no longer exists (`RiverBorrowModule`) made it look
#   covered. Found by a dead-code sweep on 2026-09-11. The entrypoint rules (1–4, 7)
#   simply find nothing in a library and fall through.
CONTRACT = re.compile(r"\b(?:contract|library)\s+(\w+)\s*(?:is\s+([^{]*))?\{")


def function_body(body: str, fname: str) -> str:
    """The body of `fname` within a contract body, brace-matched.

    ⚠ GRANULARITY IS THE POINT. Every check below used to run `.search(body)` over
    the WHOLE contract, so a contract with several entrypoints passed if ANY ONE of
    them carried the guard — a module with a guarded `takeForOnBehalf` and an
    unguarded second entrypoint was reported clean. The CALLER PIN and the DATA-SPACE
    guards are per-entrypoint obligations and are now checked per entrypoint.

    (The balance FLOOR used to stay contract-wide, because it legitimately lives in a
    private helper the entrypoint calls, e.g. `_supply` / `_repayAndSweep`. It is now
    checked over the entrypoint's REACHABLE set instead — see {reachable_body}, which
    keeps that property while attributing the floor to the seam that actually takes
    it.)
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


# All functions declared in a contract body, brace-matched, as {name: body}.
FUNCTION_DECL = re.compile(r"\bfunction\s+(\w+)\s*\(")


def all_functions(body: str) -> dict:
    out = {}
    for m in FUNCTION_DECL.finditer(body):
        out[m.group(1)] = function_body(body, m.group(1))
    return out


def reachable_body(body: str, entry: str) -> str:
    """`entry`'s body plus every function reachable from it, concatenated.

    WHY THIS EXISTS. The balance-floor test asks "does this entrypoint spend the
    module's OWN balance?", and the floor legitimately sits in a private helper
    (`_supply`, `_repayAndSweep`, `_open`). Run per-function it missed those; run
    contract-wide it could not tell WHICH seam took the floor — and once one
    contract hosts several seams, that stopped being a rounding error.

    A module merged by GRANT hosts every op that one standing authorisation covers,
    so a pull-shaped `makeOnBehalf` now routinely sits beside a pre-funded
    `takeForOnBehalf` (`DolomiteOperatorModule`). Contract-wide, the make seam
    inherits the takeFor seam's floor and is reported unpinned for a balance it
    never touches — a false positive, and a false positive on a security check is
    how a check stops being read.

    Transitive closure by NAME, which is all that is needed here: these are single
    files with no dynamic dispatch, so an identifier appearing in a body and naming
    a function of the same contract is a call.
    """
    fns = all_functions(body)
    if entry not in fns:
        return ""
    # Declaration order, entrypoint first — deterministic, so a check that reads the
    # FIRST match in the concatenation (rule 4) gets the same answer every run.
    order = [entry]
    seen = {entry}
    i = 0
    while i < len(order):
        cur_body = fns.get(order[i], "")
        i += 1
        for name in fns:
            if name in seen:
                continue
            if re.search(r"\b" + re.escape(name) + r"\s*\(", cur_body):
                seen.add(name)
                order.append(name)
    return "\n".join(fns[n] for n in order)


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
    narrow = []
    sentinels = []
    bad_ops = []
    raw_pay = []
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
            # ── (7) a multi-op module rejects an op it does not implement ──
            if OP_DISPATCH.search(body) and not OP_REJECT.search(body):
                bad_ops.append((path.relative_to(ROOT), name))

            # ── (8) no raw self-balance payout ──
            if SELF_BAL_RAW_PAY.search(body):
                raw_pay.append((path.relative_to(ROOT), name, "<inline balanceOf(this) as a transfer amount>"))
            for m in SELF_BAL.finditer(body):
                var = m.group(1)
                after = body[m.end():]
                paid_raw = re.search(
                    r"(?:safeTransfer(?:From)?|\.transfer)\([^;]*?,\s*" + re.escape(var) + r"\s*\)", after
                )
                measured = re.search(
                    r"-\s*" + re.escape(var) + r"\b|\b" + re.escape(var) + r"\s*-|\b" + re.escape(var) + r"\s*[<>]=?|[<>]=?\s*" + re.escape(var) + r"\b",
                    after,
                )
                if paid_raw or not measured:
                    raw_pay.append((path.relative_to(ROOT), name, var))

            # ── (6) no venue value-IN call is handed a max sentinel ──
            for m in VALUE_IN_CALL.finditer(body):
                callee = m.group(1)
                if (name, callee) in REPAY_SENTINEL_EXEMPT:
                    continue
                args = arg_span(body, m.end() - 1)
                hit = SENTINEL.search(args)
                if hit:
                    sentinels.append((path.relative_to(ROOT), name, callee, hit.group(0)))

            # ── (5) every data-derived pull is width-checked, not truncated ──
            for m in PULL_NARROW.finditer(body):
                expr = m.group(1)
                if expr in NARROW_SAFE_EXPR:
                    continue
                if (name, expr) in NARROW_EXEMPT:
                    continue
                narrow.append((path.relative_to(ROOT), name, expr))

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
                    # Over what `makeOnBehalf` REACHES, not the whole contract: a
                    # module merged by grant also hosts `takeOnBehalf` /
                    # `takeForOnBehalf`, whose blobs have their own layouts, and the
                    # first `abi.decode` in the file may well belong to one of those.
                    # Scanning contract-wide read the wrong seam's map.
                    m = FIRST_FIELD.search(reachable_body(body, "makeOnBehalf")) or FIRST_FIELD.search(body)
                    # ⚠ FAIL CLOSED when no unsliced decode is visible. This used to
                    #   default to "address" — i.e. a module that reads word 0 some way
                    #   this regex cannot see (a `calldataload`, a `data[0:32]` slice, a
                    #   helper in a base contract) was silently assumed safe. No shipped
                    #   maker hits this today (verified 2026-09-11); a future one must
                    #   either open with a visible decode or take a WORD0_EXEMPT row.
                    first = m.group(1).split(",")[0].strip() if m else "<no unsliced abi.decode(data, …) reachable>"
                    if first not in SAFE_FIRST_FIELD and name not in WORD0_EXEMPT:
                        word0.append((path.relative_to(ROOT), name, first))
                # Over what `makeOnBehalf` can actually REACH, not the whole contract —
                # see {reachable_body}. A merged-by-grant module's pull `makeOnBehalf`
                # must not inherit its `takeForOnBehalf` sibling's floor.
                if PRE_FUNDED.search(reachable_body(body, "makeOnBehalf")) and "_gatePreFundMake(" not in make_body:
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
            if (
                TAKE_FOR.search(body)
                and PRE_FUNDED.search(reachable_body(body, "takeForOnBehalf"))
                and not PIN_FOR.search(take_for_body)
            ):
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
            "on TAKE_FOR it is requireSettlement(spender, ...), because\n"
            "`Permit3.takeFor` is permissionless and `approveTaker` lets a caller name\n"
            "itself spender (F27/C-1).",
            file=sys.stderr,
        )
        return 1

    if sentinels:
        print(f"{len(sentinels)} venue value-IN call(s) handed a max sentinel:\n", file=sys.stderr)
        for rel, name, callee, tok in sentinels:
            print(f"  {rel}: contract {name}\n      `{callee}(... {tok} ...)`", file=sys.stderr)
        print(
            "\nI-15, the repay mirror of I-10. A venue resolves a max sentinel against ONE of\n"
            "two actors, and the call site cannot tell you which: against `onBehalfOf`'s debt\n"
            "(aave/euler/compound-v2 — merely redundant with our own clamp), or against the\n"
            "CALLER'S BALANCE (comet's `supplyTo(dst, asset, max)` does a `doTransferIn` of\n"
            "the MODULE's whole balance of `asset`). On a shared singleton the second is a\n"
            "silent cross-order fund transfer, not a revert.\n\n"
            "Pass a clamped local (`toRepay`) or the core-sized `amount`/`forAmount`. For\n"
            "\"repay everything\", use the venue's dedicated entrypoint that names the actor\n"
            "and takes no amount (`repayAll(onBehalfOf)`, `repayLoanFull(bidId)`). If the\n"
            "sentinel really does resolve against the USER, add (contract, callee) to\n"
            "REPAY_SENTINEL_EXEMPT with that reason.",
            file=sys.stderr,
        )
        return 1

    if narrow:
        print(f"{len(narrow)} data-derived pull(s) truncate to uint160 instead of Narrow160:\n", file=sys.stderr)
        for rel, name, expr in narrow:
            print(f"  {rel}: contract {name}\n      `permit3.transferFrom(..., uint160({expr}))`", file=sys.stderr)
        print(
            "\nPermit3's book is uint160. `uint160(X)` on a DATA-DERIVED amount wraps silently\n"
            "when X exceeds 2^160, so the module pulls `X mod 2^160` while a paired\n"
            "`forceApprove(token, venue, X)` approves the full X to an order-decoded venue —\n"
            "the F-2 drain. Use `Narrow160.to160(X)` (reverts on overflow), or add\n"
            "(contract, expr) to NARROW_EXEMPT with the reason X cannot exceed 2^160.",
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

    if raw_pay:
        print(f"{len(raw_pay)} self-balance read(s) are paid out RAW or never measured:\n", file=sys.stderr)
        for rel, name, var in raw_pay:
            print(f"  {rel}: contract {name}\n      `{var}`", file=sys.stderr)
        print(
            "\nA module's own balance is SHARED across every fill that transits it. Paying\n"
            "it out raw hands the next caller whatever the last one stranded (H-3, F-3) —\n"
            "and it is the one shape an interleaved call could exploit, which is why the\n"
            "module-level reentrancy guards could be dropped: every payout is a same-call\n"
            "delta. Measure `bal - floor` / `received - snapshot`, cap at `amount`, and pay\n"
            "THAT.",
            file=sys.stderr,
        )
        return 1

    if bad_ops:
        print(f"{len(bad_ops)} multi-op module(s) do not reject an unknown op:\n", file=sys.stderr)
        for rel, name in bad_ops:
            print(f"  {rel}: contract {name}", file=sys.stderr)
        print(
            "\nOps share a contract so a maker hands over ONE standing grant. That is sound\n"
            "only because the op lives inside `data`, hence inside `ref = keccak256(data)`,\n"
            "so a grant signed for one op cannot be replayed as another. A dispatcher with\n"
            "no reject branch breaks exactly that: every unknown op falls through to the\n"
            "last one, and the module runs an op the grant did not name. Add a final\n"
            "`else revert BadOp(op);` — and a `test_*_revertsOnUnknownOp` to prove it is\n"
            "reachable.",
            file=sys.stderr,
        )
        return 1

    note = f"; {dual} dual-shape, each with both data-space guards" if dual else ""
    print(f"{scanned} taker contract(s) scanned{note}")
    print(f"{makes} maker contract(s) scanned; all pin their dispatcher")
    return 0


if __name__ == "__main__":
    sys.exit(main())
