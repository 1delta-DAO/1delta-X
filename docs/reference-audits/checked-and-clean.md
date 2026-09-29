## Checked and clean

Things worth re-checking whenever the relevant code moves.

- **Selector collision on module dispatch.** Settlement calls a maker-chosen address
  directly for MAKE and SETTLE while being a universal Permit3 spender — the C1
  shape, contained only because the selector is fixed. Re-run the scan if any
  interface signature, or any external function on the scanned targets, changes:
  ```
  cast sig "makeOnBehalf(address,uint256,bytes)"                                # 0xb5d2b67f
  cast sig "settle(address,address,uint256,bytes)"                              # 0x99bb07b8
  cast sig "takeOnBehalf(address,uint256,address,bytes)"                        # 0xddbb4b79
  cast sig "takeForOnBehalf(address,address,uint256,uint256,address,bytes)"     # 0xc79f9e9d
  ```
  None may collide with any external selector on the three contracts a maker can
  name as the module:
  - **Permit3** — the last two are dispatched *by* Permit3 to a maker-chosen
    module, so Permit3 calling itself is the shape to exclude;
  - **Settlement**, including the self-call-only `fillSelf` (`0xb05d13c1`) — MAKE and
    SETTLE are called *by* Settlement, so a collision with `makeOnBehalf` or
    `settle` would let a maker-chosen module of `address(this)` self-call
    `fillSelf` and pass its `msg.sender == address(this)` check;
  - **SolverCallbackExecutor** (`execute`, `SETTLEMENT`) — Settlement's own
    trampoline, also a nameable address.

  None has a `fallback` or `receive`. Last re-run 2026-09-29 against the
  `out/core` ABIs, clean.
- **`forAmount` is ungated in `Permit3.takeFor`, by design.** The taker book bounds
  what LEAVES a position; the composite's funding leg moves value **IN** and is
  bounded instead by the maker's ordinary Permit3 **token allowance to the module** —
  the same gate a `MAKE` item's funding leg passes. The chain that makes this safe is
  worth stating because each link is load-bearing: the funding descriptor is the head
  of `data`, `data` is maker-signed, and `ref = keccak256(data)` keys the taker
  allowance — so a filler can move neither the token nor the amount, and the pull is
  capped independently. Verified end-to-end against
  `AaveV3TakeForLeverageModule`, which pulls exactly
  `permit3.transferFrom(onBehalfOf, …, collateralAsset, forAmount)`. **This is a rule
  for new composite modules:** the funding pull must go through the maker's token
  allowance, never through an allowance the module holds on someone else.
- **Any narrowing of the `matchSettle` item-op guard.** `_assertMatchShape` refuses
  `op >= SETTLE`, which bundles three different reasons under one compare. `TAKE_FOR`
  is the one to be careful with: its LITERAL and LEG-reference funding forms are
  schedule-independent and could in principle be allowed, but its **BALANCE** form
  must not be — see F16's CoW re-check above. A narrowing must therefore discriminate
  by descriptor *form*, which means decoding `data` inside the guard. Do not relax
  this on the "it is only an ordering constraint" reading.
- **The witness-typehash overloads accept an arbitrary `bytes32`.**
  `permitBatchWithWitnessHashIfNeeded` and `permitTakeWithWitnessHash` take the
  already-concatenated typehash where the string forms derive it. No new power: the
  caller already chose the typehash indirectly through the string, and a wrong hash
  simply fails signature recovery. The reachable digest set does widen to typehashes
  that no valid EIP-712 type string produces — exploiting that would need a
  pre-existing user signature over an identically-encoded struct under **Permit3's own
  domain separator**. ARITY is not what rules that out: `PermitBatchWitness` is 6
  words, and so are the SignatureTransfer structs `PermitWitnessTransferFrom` and
  `PermitBatchWitnessTransferFrom` under the same domain (`PermitTakeWitness`, at 8,
  matches none of them). Nor is word 2 — an empty `permitted[]` and an empty
  `tokens[]` both hash to `keccak256("")`. The barrier is **word 3**: an
  `address spender` there, `keccak256` of the `TakerPermit[]` encoding here, and no
  one can choose a hash output equal to a zero-padded address. Accepted. **The
  rule:** a future struct under Permit3's domain whose words 2 and 3 are BOTH array
  hashes (then `nonce, deadline, witness`) would be replayable through
  `permitBatchWithWitnessHashIfNeeded` — two empty arrays match whatever their
  element types — as would an 8-word struct laid out like
  `PermitTakeWitness` through `permitTakeWithWitnessHash`.
- **SETTLE modules pulling from the filler.** If a SETTLE module ever moved the
  *filler's* assets, an attacker acting as maker could drain fillers. Both current
  implementations pull only from the `maker` argument Settlement supplies, and both
  gate on `msg.sender == SETTLEMENT`. **This is a rule for new SETTLE modules**, not
  just an observation.
- **Duplicate input tokens on the single-order path.** `matchSettle` rejects them;
  `fill` does not. Each leg restores the balance to its snapshot before the next leg
  reads it, so the second leg measures zero proceeds rather than underflowing.
- **The pre-guard `STATICCALL`.** Four entry points arm the reentrancy guard by hand
  and run a read-only gate first, which for a proportional anchor includes a
  `balanceOf` on a maker-chosen token. Safe because it is static, and because
  `_gateFillState` reads `filled` *after* resolving the denominator. Both properties
  are load-bearing and both are asserted above `Base._enter`.
- **Item-bit / delivered-bit collision in `matchSettle`.** `DELIVERED_BIT` is bit
  255 and the packed count is a `uint8`, so the maximum item index is 254.
- **Reentrancy from the executor into a fill.** Both the single-order callback and
  the `CALL` step run while `_locked == 2`. The unguarded external functions
  reachable from there — `approveOrder`, `cancelOrder`, `setOrderSigner`, the nonce
  cancellations — are all keyed on `msg.sender`.

- **Any new multicall / router / aggregator surface must refuse `target ==
  address(this)`** (fifth pass, the multicall-router incident) — and an ALLOWLISTED
  router carrying CALLER-chosen calldata is the same shape one hop out: the router's
  `msg.sender` is our contract, so its standing approvals are the caller's to spend
  (F30, `AggregatorFillSolver` standing mode — closed by requiring an operator set,
  `StandingNeedsOperators`). Re-check whenever a contract both holds a standing
  approval and forwards caller calldata.
- **A delta-verify order is fillable by its named `exclusiveFiller` only** (F30).
  Anything that widens who may run a bit-104 callback — a filler set, a soft
  override, an exclusivity window — reopens "a balance delta cannot tell this fill's
  delivery from the maker's other paid inflow". `Core._snapshotOutRecipients`.
- **A witness permit must name the settler that consumes it** (F30). If another
  witnessed entrypoint is added, its witness needs `address(this)` in it; Permit3's
  domain does not provide it. `Core._permitBatchHead`.
- **No 1271 wallet we ship may trust Permit3 without rehashing** (F30,
  `PositionFunnel`). Permit3 structs name no owner.

---
