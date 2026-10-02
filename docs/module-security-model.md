# Module security model

The lending/transfer/bridge modules are **shared singletons** that act on a
maker's protocol position under a maker signature, dispatched by Settlement or by
Permit3. This document is the top-level statement of *what each module is allowed
to assume*, and — the part that matters — *which automated check enforces each
assumption*, so that the failure mode this repository keeps hitting does not recur:

> a rule that is re-typed per call site is a rule that eventually misses a site.

Every finding in the 2026-09 audit was an instance of that: a guard present on one
branch and absent on its neighbour ten lines away (`Narrow160` on `_open` but not
`_close`), on one of five siblings, on the direct setter but not its relayed twin.
The countermeasure is not vigilance; it is to move each invariant from prose into
`tools/check-module-shapes.py` (syntactic, source-level) or into a named test, and
to record here which one carries it. **A row with measurement "prose only" is a
latent version of the next audit finding — treat it as a TODO, not a state.**

---

## 1. Trust model

| Actor | Trust | Consequence |
| --- | --- | --- |
| **Maker** | signs the order; may name themselves maker of *any* order | order `data` (venues, tokens, amounts, descriptors) is attacker-choosable — a maker can author a hostile order against a singleton |
| **Solver / filler** | untrusted | controls matching, ordering, `matchSettle` schedules, and may deploy arbitrary contracts (fake pools, fake tokens, fake modules) and pass them where an address is caller-supplied |
| **Settlement** | trusted; the only legitimate dispatcher | an approved Permit3 spender in every maker's book; the caller pin every module rests on |
| **Permit3** | trusted hub, but its `take` / `takeFor` entrypoints are **permissionless** | `approveTaker` lets any caller name *itself* spender, so `msg.sender == permit3` authorises **nothing** on its own — a module reached through Permit3 always resolves `onBehalfOf` to the grantor, i.e. the attacker themselves on a self-grant |
| **Venue** (pool/vault/comet/morpho/provider/EVC) | decoded from order `data` ⇒ **attacker-choosable** | any `forceApprove(token, venue, X)` hands `X` to attacker code; must be scoped to what the fill delivered and cleared after |

### Deployment assumptions (the ones that make the residue guards defense-in-depth)

Two assumptions are relied on repeatedly and are stated here once so their scope is
explicit. If either is ever weakened, the guards keyed to them (§2, rows tagged
**[A1]/[A2]**) move from defense-in-depth back to load-bearing.

- **[A1] No fee-on-transfer or rebasing token is a lending reserve.** Such tokens
  break a lending protocol's own scaled-balance accounting, so they are not listed
  as borrow/collateral reserves — they exist only as DEX assets. Consequence: a
  supply/deposit consumes *exactly* the amount delivered, so **no fill leaves
  residue on a module**. (Caveat: Morpho Blue, Silo, Euler v2 (permissionless EVK
  vaults named in `data`), Morpho Midnight and Teller have *permissionless*
  markets. A maker can sign against a market someone created with an exotic token.
  That reintroduces under-consumption, but scoped to a maker who chose a broken
  market — self-harm, not third-party theft. It is a policy about *our*
  integrations, not a protocol guarantee, on those venues. 2026-09-30 L-LIB-9 swept
  all 17 pre-fund venues for this list.) **Under a nominal fee-on-transfer
  delivery** the pre-fund floor is `pre - fee` (`PreFundGuard.floorOf` assumes the
  delivery arrived whole), so the fee is drawn from third-party residue — bounded by
  [A2] to dust — or the fill fails closed. This is accepted (L-LIB-9): core stays
  asset-general. Delta-verified delivery (timing bit 104) is unaffected.

- **[A2] A module holds no persistent balance across a transaction boundary.**
  Every module pulls/receives and consumes/forwards within one call and sweeps any
  excess to the maker. Combined with [A1], the only sources of a resident balance
  are wei-scale rounding dust and external donation — and a self-donation nets zero
  to the donor, so third-party residue is dust. This is *not* an enforceable
  invariant (donation is permissionless), only an unprofitable-to-violate one.
  Two modules hold balances on purpose and say so: `PermissionlessCallModule` can
  receive a caller bounty, which it forwards to the maker when the spec names a
  `bountyToken` and otherwise leaves on the module (claimable by the next caller);
  and `ERC4626WithdrawModule` holds pending requests, so it floors BOTH the
  data-named share token and the vault's own share token (MISC-MOD-3).

### The core consequence used throughout

A module can only ever be drained of **its own balance**, and a `take`/`takeFor`
reached by a self-grant resolves `onBehalfOf` to the attacker. So a drain requires
**both** (a) a persistent balance on the module — excluded by [A1]+[A2] except by
donation — **and** (b) a permissionless entrypoint on that *same contract* that
pays its balance out on attacker parameters. The guards below are ordered by which
of those two they close.

### Position-access grants: Permit3 funding vs venue-native authorization

Two distinct grants a module may need, and they live in different places on purpose:

- **Funding pulls (wallet tokens → position):** deposit/repay/supply legs pull the
  user's *wallet* underlying, which is exactly what Permit3 is for — `permit3.transferFrom`.
- **Position access (move/redeem an existing position):** this is a grant *to the
  module*, on the venue's own authorization surface, NOT Permit3. Comet `allow`,
  Venus `updateDelegate`, Morpho `setAuthorization`, and — since 2026-09 — the Aave
  **aToken ERC-20 approval to the module** (`aToken.approve(module)`, or an EIP-2612
  permit to the module), which the withdraw modules pull with a direct
  `safeTransferFrom`. Aave has no withdraw-on-behalf, so the position receipt (the
  aToken) must pass through the module; approving the module to move it is the
  position-access grant, the Aave analogue of the flags above. The taker-book grant
  consumed by {Permit3.take} still authorizes the *withdraw operation*; the aToken
  approval is the second, position-token grant. (Before 2026-09 the aToken pull went
  through Permit3's token book — that made Aave the lone module routing position
  access through Permit3 instead of the venue surface; it now matches its siblings.)

---

## 2. Fake modules and fake lenders: why matching is safe

The sharpest form of the threat model is: *a solver crafts an order whose `module`
or venue is an attacker-deployed contract that returns success but delivers
nothing, and nets it against a real user's limit order to walk away with the
user's assets.* This cannot drain a third party or the pool, in a single fill or
in `matchSettle`. The reasons, in order of how load-bearing they are:

**(a) The address is signed — you cannot swap it into someone else's order.** Both
the `module` (per item) and the venue (`pool`/`vault`/`comet`, decoded from `data`)
live inside the maker-signed order, and for a taker dispatch inside
`ref = keccak256(data)` which keys the Permit3 allowance. Changing either byte
invalidates the maker's signature and points the allowance at a `ref` nobody
granted. So a fake module/venue can appear **only in an order the attacker authored
themselves**, where `onBehalfOf == maker == attacker` and everything it touches is
the attacker's own position and grants.

**(b) A fake module has no authority when called.** Called by Settlement (MAKE) or
Permit3 (TAKE) it runs as a nobody: `Permit3.transferFrom/take` from inside it keys
the spender by `msg.sender` = the fake module, which no victim approved (reverts);
re-entering Settlement hits `nonReentrant`; and in a match the solver's arbitrary
`(target,data)` call runs through `SolverCallbackExecutor`, an **allowance-less**
identity that is an approved spender for no one.

**(c) A fake module can fake a *call* but not a *balance*.** This is the crux for
matching. Every asset a maker receives is a real `safeTransfer` out of the
Settlement pool, and the pool only ever holds what was really pulled/delivered in.
A fake TAKE credits **measured** proceeds (the balance delta around the module
call) — zero for a module that moves nothing — so it leaves the order
`LegUnfunded`; a fake MAKE acts on the attacker's own position and produces nothing
for a counterparty. There is no step where "a module reported success" substitutes
for the pool actually holding the token.

**(d) Two core guards make input-pull and output-deliver inseparable.**

  - **Per-order completeness** (`PlanIncomplete` / `LegUnfunded`): an order fills
    all-or-nothing — its inputs are pulled *only if* every one of its output legs is
    delivered by a real transfer from the pool.
  - **Wholeness floor** (`_sweepSurplus`: `nowBal >= beforeBal` per touched token →
    `BatchNotWhole`): the context may not leave Settlement down on any token, so a
    maker's output cannot be sourced from the pool's own or donated balance — it has
    to come from a real inflow.

### Worked trace — non-delivering counter-order vs a real limit order

Real user **M** signs: `legsIn = [1000 USDC]`, `legsOut = [0.5 WETH]`. Attacker **A**
wants M's USDC for free via a `FakeWethSource` module. Every schedule A can build:

| Schedule | Where it dies |
| --- | --- |
| PULL(M,USDC) → DELIVER(USDC→A), omit M's WETH | `PlanIncomplete` — M's output leg never delivered |
| PULL(M,USDC) → ITEM(A, fake take "0.5 WETH") → DELIVER(WETH→M) | `safeTransfer` reverts — pool holds 0 WETH (fake produced none) |
| Source M's WETH from pool's donated WETH, then deliver | `BatchNotWhole(WETH)` — floor `nowBal < beforeBal` |
| PULL(A, real 0.5 WETH) → PULL(M,USDC) → both DELIVER | succeeds — but A gave real WETH (an honest fill, no exploit) |

So the match either **reverts** or is a **fair trade**. The only thing a fake
module/venue can ever reach is a **module's own stranded balance** (the F-3 residue
class), never the pool and never a third party. This is verified structurally
above and is a candidate for a pinned PoC test (`FakeNonDeliveringModule` +
`matchSettle`) — see §3.

## 2b. Invariant → measurement matrix

`shapes` = enforced by `tools/check-module-shapes.py` (run as `make modules-check`,
source-level, fails CI). `test` = a named test. `gate` = a `make` target. `prose`
= **not yet mechanised — a gap.**

| # | Invariant | Why | Measurement |
| --- | --- | --- | --- |
| I-1 | Every `makeOnBehalf` pins `msg.sender == settlement` | MAKE is dispatched Settlement→module directly; without the pin anyone drives the module against any position the maker approved it for | **shapes** (check 2) |
| I-2 | Every pre-funded `takeForOnBehalf` pins the forwarded `spender == settlement` | `Permit3.takeFor` is permissionless (F27/C-1); the pin is the only thing separating a Settlement fill from a self-granted direct call | **shapes** (check 3) |
| I-3 | A contract hosting both `takeOnBehalf` and `takeForOnBehalf` carries both data-space guards (`requirePlainTake` + `requireLegRef`/`requireFundingDescriptor`) | the taker book keys on `keccak256(data)` and cannot tell the two dispatches apart; disjoint word-0 spaces make one `ref` unable to authorise both | **shapes** (check 1) |
| I-4 | A pull-shaped `makeOnBehalf` blob is not readable as a pre-fund descriptor (word 0 opens with an `address`/dynamic offset, `>> 253 == 0`) | `Base._runItem` classifies pre-fund by `word0 >> 253 == 5`; a colliding blob is sized from the descriptor, not `item.amount` | **shapes** (check 4, with `WORD0_EXEMPT`) |
| I-5 | A data-derived Permit3 pull amount is `Narrow160.to160(X)`, never `uint160(X)` | `uint160(X)` wraps silently; a paired `forceApprove(venue, X)` then hands the untruncated `X` to an attacker-decoded venue — **the F-2 drain** | **shapes** (check 5, with `NARROW_EXEMPT`) |
| I-6 | A pre-fund module spending from its own balance takes a balance floor (`floorOf`/`requireDelivered`) bound to the asset it moves, and the funding-token is bound to the leg | the core binds BOTH the leg's recipient (bit 253) and its token (`Base._forSlice` reverts `ForLegInvalid` when the descriptor's token is not the leg's — since F27's follow-up; the "recipient but not token" wording here was stale until 2026-09-30, X-SPEC-5); the module still floors the asset it actually spends | **shapes** (check 3 detects the floor; token binding is in `PreFundGuard.floorOf`) + **test** (per-package leverage suites) |
| I-7 | `AaveV3CreditModule._fundedSupplyLeg` sweeps its pre-fund surplus to the maker | it is the one contract where residue *and* a permissionless primitive (`takeOnBehalf` ratio path) co-locate; residue there is drainable **[A2]** | **test** (aave-v3 fork leverage suite) — *prose for the invariant itself* |
| I-8 | A `Full`-mode leg makes **ONE venue withdraw of the whole position to itself**, then splits it with ERC-20 transfers — and **requires `received >= amount`** (`FullFillGuard.requireDelivered`) before doing so. `received` is a balance delta against a `floor` taken before the withdraw | the split is cheaper than a second venue call, but it removed a bound the venue used to enforce for free: the OLD form called the venue *for the signed amount*, so a short position reverted inside it. Nothing does now, and the substitute this row used to cite (Settlement's output validation) does **not** cover this side of the ledger — a withdraw item funds an INPUT leg, and `Core._payInputsToSolver` silently pulls `owed - proceeds` from the **maker's wallet**. So the guard is back, and it is safe *only* on `Full` legs, where `amount == totalAmount` is the maker's signed TOTAL rather than a pro-rated slice. The `floor` + `min(received, amount)` cap stays too: it is what stops a stray module balance being paid out (H-3). **Restored 2026-09-10 after the audit; do not remove either half** | **test** (per-package withdraw + loop-close suites) |
| I-8b | Where the venue **cannot** name a recipient (proceeds land at the caller by construction: every borrow leg, cToken `redeem`, aave-v4's PM, native unwrap), the leg **delivers the measured `received`** (a `balBefore` snapshot excludes residue), **capped at `amount`**, with any excess to the maker — never a nominal `amount`. **This is the CAP, not a substitute for I-8's BOUND**: a forced-custody leg whose branch asserts `amount == totalAmount` (`requireFullFillFromData`) is a `Full` leg and carries `requireDelivered` too | a nominal payout on a short/fake-pool delivery would be topped up from a stray module balance (H-3); capping at `received` makes that structurally impossible. ⚠ An earlier version of this row said the cap "replaces the old `require(received >= amount)` gate" and exempted these legs because "there `amount` IS a slice" — false for their `Full` branches, where `amount` is the signed TOTAL. That prose, mirrored in `check-module-shapes.py`, is why five Full branches (Venus, aave-v4, compound-v2 ×2, lista-native) shipped without the bound until the 2026-09-12 audit; shapes rule 9 now enforces `requireFullFillFromData ⇒ requireDelivered`. ⚠ **"Proceeds land at the caller by construction" is NOT true of every venue** (2026-09-30): Liquity v2's value-out goes to the trove's stored remove-manager RECEIVER, which survives a TroveNFT transfer, so `LiquityV2TakerModule` now bounds both Exact value-out ops with `requireDelivered` (G-VENUE_B-1). And Exact branches are no longer cap-only on venues that CLAMP a short withdraw or charge a redeem fee: `AaveV4WithdrawModule` Exact, `VenusTakerModule` Exact withdraw, `CompoundV2WithdrawModule` and `CompoundV2NativeWithdrawModule` Exact call `requireDelivered` (safe on a slice, because the venue call is sized at the slice), `ExactlyTakerModule`'s fixed withdraw pre-checks the position (`ShortFixedPosition`), and the Midnight borrow leg (`requireFullFill` + min cap) carries it too (L-CV2-1 / L-CV2-1.v1/.v2). The premise "every other venue's Exact withdraw reverts on a short position" is false for Comet, Dolomite, the Aave v4 spoke and Exactly `withdrawAtMaturity`; rule 9 lists the clamping venues it knows (`CLAMPING_VENUE_MODULES`) | **shapes** (rule 9, incl. the clamping-venue list) + **test** (borrow/withdraw suites) |
| I-9 | A native leg spends/delivers the measured unwrap delta (`{value: received}` / `safeTransfer(receiver, min(received, amount))`), not the signed amount | a fake `wnative` makes `withdraw` a no-op; spending the nominal amount would draw the module's own native. Custody is forced (raw native must land here to be wrapped), so this is I-8b's form | **test** (lista/compound native suites) + this posture |
| I-10 | A Full-mode leg **never passes the venue a max sentinel** (`type(uint256).max`, aave's `0xffff…`). "Full" is resolved from the *user's own* position (`balanceOf`/`previewRedeem(balanceOf(user))`/`position().collateral`/`collateralBalanceOf`) and then spent as exact amounts. For Silo, Gearbox and Exactly `positionOf` is `previewRedeem(balanceOf(user))`, the RAW position — NOT `maxWithdraw`, which is a reachability figure capped by liquidity (2026-09-30 G-VENUE_B-9) | a venue max burns whatever the **module** holds too — an aave `withdraw(max)` burns the module's own aTokens, which is what previously forced a two-stage "harvest" and a delta measurement (**the F-3 shape**). Resolving from the user's balance deletes the whole class, and is what makes I-8 possible | **shapes**-eligible (grep for a max sentinel in a venue amount) — *prose today* |
| I-11 | A dual-layout module (`takeOnBehalf` + `takeForOnBehalf`) decodes its `IProceedsAsset`/`IFundingSource` views on the word-0 discriminator, not a single fixed layout | the two seams have different byte maps; a blind decode returns the wrong token to `SettlementLens`, defeating the off-chain stranded-proceeds preflight — **the F-4 shape**. `IProceedsAsset` implementers (2026-09-30 L-CMT-6): `CometTakerModule`, `VenusTakerModule`, `CompoundV2WithdrawModule`, `CompoundV2NativeWithdrawModule`, `AaveV4WithdrawModule`, `AaveV4BorrowModule`, `AaveV2WithdrawModule`, `AaveV2BorrowModule`, besides `AaveV3WithdrawModule`, `AaveV3CreditModule`, `MorphoBlueTakerModule` (per op), `DolomiteOperatorModule` (registry tokens), `EulerV2OperatorModule` and `FluidTakeForModule`. `IPositionSource` implementers include `AaveV2WithdrawModule`, see [position-sized-fills.md](position-sized-fills.md) | **prose** — *candidate for a `shapes` check* |
| I-12 | A relayed delegate-signer permit with `0 < expiry < now`, or with an expiry below the stored value, is **refused** (`SignerPermitExpired`); only an explicit `expiry == 0` revokes and burns the permit word. (A direct `setOrderSigner` that lowers the expiry also burns the word, X-DIFF-CORE-3) | normalising a lapsed relayed permit to a revocation let anyone holding a stale permit revoke a live desk key (F29 finding 7); the earlier "normalise to 0" wording of this row described the superseded behaviour (2026-09-30 X-SPEC-5) | **test** (`test_relayedPastExpiryPermit_isRefused`, `DelegateRevocationResurrect`) |
| I-13 | Settlement stays within EIP-170 | a fix that spends the last bytes bricks deployment | **gate** (`make size-check`, clean `out/core-deploy`) |
| I-15 | A value-IN (repay/supply) leg **never hands the venue a max sentinel**. "Repay everything" is either a clamp against the user's own live debt spent as an exact amount, or a DEDICATED venue entrypoint that names the actor and takes no amount at all (`repayAll(onBehalfOf)`, `repayLoanFull(bidId)`, fluid's `operate` where the position NFT is the actor) | the repay mirror of I-10, and the more dangerous half because it reads as a convenience. A venue resolves a sentinel against one of two actors and the call site cannot tell you which: against **`onBehalfOf`'s debt** (aave `repay(asset, max, …)`, euler `repay(max, account)`, compound-v2 `repayBorrowBehalf(user, -1)` — merely redundant with the clamp we already do), or against the **caller's balance** — comet's `supplyTo(dst, asset, max)` `doTransferIn`s the **module's** whole balance of `asset`. On a shared singleton that is *"supply everything this contract happens to be holding, including another order's residue, into this order's position"* — the F-3 shape with the sign flipped, and a silent cross-order transfer rather than a revert. Gearbox is the one module with no clamp (it has no cheap debt read); it is safe because `decreaseDebt` caps and the surplus lands as collateral on the **maker's own** account, but it is therefore a forced `Recycle` with no sweep-to-user path — see the module header. EVK `repay` **reverts** `E_RepayTooMuch` above the debt (only the max sentinel resolves to the full debt), so the Euler `debtOf` clamps are load-bearing, not redundant (2026-09-30 L-ED-4) | **shapes** (check 6) + **test** (`gearbox-v3/test/fork/CreditFlow.t.sol`, `fluid/test/integration/FluidFullClose.t.sol`, `dolomite/test/integration/RepayToZero.t.sol`, euler `EulerRepayModuleForkTest`). *Check 6 reads call sites only — a sentinel laundered through a helper (fluid's `_negDelta`) is outside its reach, and it cannot see SHARE-denominated venue pulls: `MorphoBlueRepayModule`'s Recycle repaid by shares under a standing max approval and drew module residue (L-LIB-1). It now repays by shares only when `amount >=` the accrued debt, scopes and clears its approvals, and reverts `FloorBreached` below the floor; shapes rules 14/15 now catch the standing-approval half* |
| I-16 | A module **never pays out a raw self-balance**: every `balanceOf(address(this))` is a floor or a delta — `bal - floor`, `received - snapshot`, `min(received, amount)` — and is what a payout is sized from. **This is the invariant the module-level reentrancy guards were standing in for, and the reason there are none on the merged operator/credit modules.** | Every module entrypoint sits behind a locked dispatcher (Settlement for MAKE, `Permit3.take`/`takeFor` for the taker seams) except ONE window Permit3 leaves open on purpose: `AllowanceTransfer.transferFrom` is deliberately un-guarded, so a MAKE pull hands control to a maker-chosen token whose hook can call `Permit3.take`. That hook can only reach `takeOnBehalf(X, …)` for an X that granted the *hook contract* a taker bucket — the attacker, never the victim (core `test_reentrancy_transferFrom_cannotReachTheSpendersBucket`). So the only exposure is an interleaved call, on the attacker's own account, on the SAME module balance the victim's fill is measuring — and a same-call delta is unmoved by anything added to or drained from that balance in between. A raw payout would break this (and would already be H-3/F-3). The 2026-09-11 review restored, then removed, `DolomiteOperatorModule`'s guard on this argument; the census found all 77 self-balance reads in the tree already delta-measured | **shapes** (check 8) + **test** (dolomite `ReentrancyWindow.t.sol` runs the un-locked window with a hook re-entering `Permit3.take` mid-repay and asserts the victim's outcome is byte-identical to an un-attacked fill). *A future path that genuinely needs a raw balance needs the guard back AND a written reason for the checker* |
| I-14 | Doc-cited tests exist; module READMEs name real contracts; every `@N` layout offset in a module README row or in `gasless-permit-relay.md` is an offset the contract reads | prose drifts ahead of code; a citation to a renamed/deleted test hides that, and a README byte map one word off builds unfillable (or silently downgraded) blobs (L-CENSUS-4, L-LIB-6) | **gate** (`make docs-check`) |
| I-17 | Every non-zero `forceApprove(token, spender, X)` in a module is cleared (`forceApprove(…, spender, 0)`) on the same entrypoint's reachable path, and a standing `ensureApproval` appears only toward an allow-listed pinned immutable | a standing approval on a shared singleton gives the venue (often order-decoded) a claim on the next caller's residue — the L-LIB-1 shape | **shapes** (checks 14, 15, with `APPROVE_EXEMPT` / `ENSURE_APPROVAL_OK`) |
| I-18 | A token whose balance a TAKE seam measures is derived from the venue, compared against it, pinned, or keys the venue call | a measured `data`-named token the venue does not pay out measures 0 and strands the real proceeds while the core bills the maker (L-CV2-4, G-BYTE_MAP-7, L-LRG-1) | **shapes** (check 16, with `MEASURED_TOKEN_EXEMPT`) |
| I-19 | A SETTLE module never pulls from the filler, moves no unscaled `data` amount without `FullFillGuard`; an approval clear is never behind an early return; a pre-fund header does not describe the retired TAKE_FOR shape | X-SPEC-1, X-ARITH-3, X-STATIC-1.v1, L-LRG-4c / L-CENSUS-6 | **shapes** (checks 10–13; 13 keys on the pre-fund SHAPE, not on `*PreFundModules.sol` file names, so `ListaBrokerModule`'s pre-fund branch is covered) |

All shapes checks run over **comment-stripped** source since 2026-09-30 (L-CENSUS-7):
a pin or guard that existed only in a comment used to satisfy them. Each rule added
by that remediation has a fires/stays-quiet self-test in `tools/test-module-shapes.py`.

---

## 3. Gaps, ranked

The **prose** rows above are where the next missed-sibling will hide. In priority
order:

1. **I-11 (dual-layout view decode).** Cleanly syntactic: a contract implementing
   both taker seams whose `proceedsAsset`/`fundingSource` do a single
   `abi.decode(data, ...)` without branching on `data[0:32] >> 253` is a candidate
   offender. Worth adding to `check-module-shapes.py` as check 6.
2. **I-8 / I-8b / I-9 / I-10 (delivery family) — POSTURE NOTE, CORRECTED 2026-09-10.**
   The shape is one venue withdraw + an ERC-20 split, with **two** guards, and the
   2026-09 audit established that both are load-bearing:
   - the **cap** `min(received, amount)` with a pre-call `floor` — stops a stray or
     donated module balance topping up a short delivery (H-3);
   - the **bound** `received >= amount` on `Full` legs — restores what the venue
     enforced before the split rewrite.
   ⚠ **The earlier version of this row told readers not to add the bound back.** That
   was wrong, and the reason it was wrong is worth keeping: it justified the removal
   by pointing at "Settlement's output validation", which does not exist on the input
   side. A withdraw item funds an INPUT leg, and `Core._payInputsToSolver` handles
   `proceeds < owed` by pulling the difference out of the maker's wallet — silently,
   with the order marked fully consumed. Removing the gates was safe *while* the venue
   call was sized at `amount`; the sweep took that away and the gate was already gone.
   Neither change was wrong alone. The composition was.
   The bound belongs on `Full` legs ONLY (there `amount` is the signed total, so it
   cannot misfire on a partial). ⚠ "`Full` leg" is decided by the BRANCH, not the
   venue: I-8b's forced-custody venues (cToken `redeem`, aave-v4's PM, lista-native)
   have Exact branches where `amount` IS a slice and the cap alone is right — and
   `Full` branches where it is the signed total and the bound is mandatory. The
   earlier wording exempted the venues wholesale, and five of their Full branches
   shipped without the bound until the 2026-09-12 audit (finding 4). Shapes rule 9
   now ties `requireFullFillFromData` to `requireDelivered` mechanically.

3. **I-6 / I-7 (residue floor + sweep).** Under **[A1]+[A2]** these are
   defense-in-depth on every contract except `AaveV3CreditModule` (I-7), where the
   sweep is load-bearing. The 2026-09 re-assessment **removed** the sweep from the
   five settlement-gated pre-fund modules (Morpho ×2, Silo, Lista, Dolomite/Euler
   pre-fund TakeFor) because they expose no permissionless primitive to drain the
   residue — see `[[audit-2026-09-08-fixes]]`. Do **not** re-add sweeps to a
   settlement-gated module on "consistency" grounds; add one only where a
   permissionless self-balance-paying primitive co-locates.
   ⚠ That rule is about sweeping **pre-existing residue** (balance below the
   floor). It is NOT about the fill's own delivery: every pre-fund op — repay
   halves since F27, deposit halves since F28 (2026-09-12) — takes `floorOf` and
   `sweepSurplus(asset, onBehalfOf, floor)`, returning whatever the venue did not
   consume of THIS fill's delivery to the maker. That is value the solver already
   paid for the maker, not residue defence, and a `requireDelivered`-only deposit
   op was the one place a venue consuming less than instructed could strand it.

---

## 4. When you add a module

Before it ships, `make modules-check` must pass, which means:

- a `makeOnBehalf` pins `settlement` (I-1);
- a pre-fund `takeForOnBehalf` pins `spender` (I-2) and takes a floor (I-6);
- a dual-shape contract carries both data-space guards (I-3);
- a pull `makeOnBehalf` opens `data` with an `address`/dynamic struct, or is added
  to `WORD0_EXEMPT` with the reason (I-4);
- every `uint160(X)` feeding a pull is `Narrow160.to160`, `amount`/`forAmount`, or
  added to `NARROW_EXEMPT` with the reason `X <= 2^160` (I-5);
- no venue value-IN call is handed a max sentinel — pass a clamp against the user's
  own debt, or use the venue's dedicated no-amount "repay all" entrypoint (I-15).

If the module holds a balance and exposes a permissionless entrypoint, it needs the
sweep (I-7) and the borrow/withdraw/native measured-delta guards (I-8/9/10) — and it
should grow a test named in §2 so the obligation is visible, not remembered.

A repay leg carries one obligation the checker cannot see: **prove it closes to
exactly zero after real accrual**, not in the same block the position was opened.
The same-block form is the degenerate case where the live debt equals the signed
principal and a stale quote is indistinguishable from a live one. Most venues in
the tree have a `vm.warp`-then-close test, and three of them behave differently
there (fluid needs its sentinel, gearbox reverts below `minDebt` unless over-signed,
aave-v4's share-denominated debt still lands exactly on zero). **Euler v2 still has
none** (2026-09-30 L-ED-4): its repay fork test (`EulerRepayModuleForkTest`) closes
in the opening block.
