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
  residue on a module**. (Caveat: Morpho Blue and Silo have *permissionless*
  markets. A maker can sign against a market someone created with an exotic token.
  That reintroduces under-consumption, but scoped to a maker who chose a broken
  market — self-harm, not third-party theft. It is a policy about *our*
  integrations, not a protocol guarantee, on those two venues.)

- **[A2] A module holds no persistent balance across a transaction boundary.**
  Every module pulls/receives and consumes/forwards within one call and sweeps any
  excess to the maker. Combined with [A1], the only sources of a resident balance
  are wei-scale rounding dust and external donation — and a self-donation nets zero
  to the donor, so third-party residue is dust. This is *not* an enforceable
  invariant (donation is permissionless), only an unprofitable-to-violate one.

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
| I-6 | A pre-fund module spending from its own balance takes a balance floor (`floorOf`/`requireDelivered`) bound to the asset it moves, and the funding-token is bound to the leg | the core binds the leg's recipient (bit 253) but not its token; the module is the only place that sees the asset it actually spends | **shapes** (check 3 detects the floor; token binding is in `PreFundGuard.floorOf`) + **test** (per-package leverage suites) |
| I-7 | `AaveV3LeverageModule._supplyLeg` sweeps its pre-fund surplus to the maker | it is the one contract where residue *and* a permissionless primitive (`takeOnBehalf` ratio path) co-locate; residue there is drainable **[A2]** | **test** (aave-v3 fork leverage suite) — *prose for the invariant itself* |
| I-8 | A leg whose venue **can** name a recipient pays **exact amounts direct to their destinations** — the signed `amount` to `receiver`, the remainder to `onBehalfOf` — and never routes proceeds through the module | with no custody there is nothing to measure, nothing to split, and a stray module balance is structurally excluded from the payout. This is the composer's convention (`contracts-delegation` `AaveLending._withdrawFromAave`) and, since 2026-09, ours for every Full-mode withdraw whose venue takes a receiver: aave-v2/v3, comet, morpho-blue (×2), midnight (×2), lista, silo, exactly, gearbox, euler | **test** (per-package withdraw suites) |
| I-8b | Where the venue **cannot** name a recipient (proceeds land at the caller by construction: every borrow leg, cToken `redeem`, aave-v4's PM, native unwrap), the leg **delivers the measured `received`** (a `balBefore` snapshot excludes residue), **capped at `amount`**, with any excess to the maker — never a nominal `amount` | a nominal payout on a short/fake-pool delivery would be topped up from a stray module balance (H-3); capping at `received` makes that structurally impossible, and a short delivers less and fails the fill's output check downstream. **Replaces the old `require(received >= amount)` gate** (dropped 2026-09 as reviewer-confusing; the cap is the same protection without a revert) | **test** (borrow/withdraw suites) + this posture |
| I-9 | A native leg spends/delivers the measured unwrap delta (`{value: received}` / `safeTransfer(receiver, min(received, amount))`), not the signed amount | a fake `wnative` makes `withdraw` a no-op; spending the nominal amount would draw the module's own native. Custody is forced (raw native must land here to be wrapped), so this is I-8b's form | **test** (lista/compound native suites) + this posture |
| I-10 | A Full-mode leg **never passes the venue a max sentinel** (`type(uint256).max`, aave's `0xffff…`). "Full" is resolved from the *user's own* position (`balanceOf`/`maxWithdraw`/`position().collateral`/`collateralBalanceOf`) and then spent as exact amounts | a venue max burns whatever the **module** holds too — an aave `withdraw(max)` burns the module's own aTokens, which is what previously forced a two-stage "harvest" and a delta measurement (**the F-3 shape**). Resolving from the user's balance deletes the whole class, and is what makes I-8 possible | **shapes**-eligible (grep for a max sentinel in a venue amount) — *prose today* |
| I-11 | A dual-layout module (`takeOnBehalf` + `takeForOnBehalf`) decodes its `IProceedsAsset`/`IFundingSource` views on the word-0 discriminator, not a single fixed layout | the two seams have different byte maps; a blind decode returns the wrong token to `SettlementLens`, defeating the off-chain stranded-proceeds preflight — **the F-4 shape** | **prose** — *candidate for a `shapes` check* |
| I-12 | A relayed delegate-signer revocation normalises a lapsed expiry to `0` (burns the permit word), matching the direct setter | otherwise a stale unrelayed nomination resurrects a revoked delegate — **the F-1 shape** | **test** (`DelegateRevocationResurrect` relayed cases) |
| I-13 | Settlement stays within EIP-170 | a fix that spends the last bytes bricks deployment | **gate** (`make size-check`, clean `out/core-deploy`) |
| I-14 | Doc-cited tests exist | prose drifts ahead of code; a citation to a renamed/deleted test hides that | **gate** (`make docs-check`) |

---

## 3. Gaps, ranked

The **prose** rows above are where the next missed-sibling will hide. In priority
order:

1. **I-11 (dual-layout view decode).** Cleanly syntactic: a contract implementing
   both taker seams whose `proceedsAsset`/`fundingSource` do a single
   `abi.decode(data, ...)` without branching on `data[0:32] >> 253` is a candidate
   offender. Worth adding to `check-module-shapes.py` as check 6.
2. **I-8 / I-8b / I-9 / I-10 (delivery family) — POSTURE NOTE.** The preferred form is **I-8: no custody at all.** If the venue takes a `receiver`, pay it exact amounts direct — the signed `amount` to `receiver`, the remainder to `onBehalfOf`. Do not withdraw to the module and re-transfer, and (I-10) do not pass a max sentinel to resolve "full"; read the user's own balance instead. **I-8b is the fallback only where the venue's API forces custody** (borrows, cToken `redeem`, aave-v4's position manager, native unwrap). Those legs deliberately carry **no `require(received >= amount)` gate** (removed 2026-09 as reviewer-confusing — it read like dead code because a real lender is exact). The protection is instead structural: the payout is `safeTransfer(receiver, received < amount ? received : amount)` (and `{value: received}` for native), so it can **never exceed what this fill actually withdrew** and therefore can never dip into a stray/donated module balance. A genuine short delivers less and is caught by Settlement's output validation, not a module revert. **Do not "add back" a `received >= amount` check** — its absence is intentional and this row is where that is recorded. Where custody remains, the measurement and the residue exclusion it feeds are load-bearing and must stay; only the revert gate was dropped. These are still
   "the amount forwarded/spent must be a measured balance delta, not a nominal." A
   weak proxy (flag `{value: <ident>}` and `safeTransfer(receiver, amount)` that are
   not preceded by a `balanceOf` delta in the same function) would have false
   positives; today these rest on per-package tests. Keep them as tests, but list
   the tests here so a module added without one is visible.
3. **I-6 / I-7 (residue floor + sweep).** Under **[A1]+[A2]** these are
   defense-in-depth on every contract except `AaveV3LeverageModule` (I-7), where the
   sweep is load-bearing. The 2026-09 re-assessment **removed** the sweep from the
   five settlement-gated pre-fund modules (Morpho ×2, Silo, Lista, Dolomite/Euler
   pre-fund TakeFor) because they expose no permissionless primitive to drain the
   residue — see `[[audit-2026-09-08-fixes]]`. Do **not** re-add sweeps to a
   settlement-gated module on "consistency" grounds; add one only where a
   permissionless self-balance-paying primitive co-locates.

---

## 4. When you add a module

Before it ships, `make modules-check` must pass, which means:

- a `makeOnBehalf` pins `settlement` (I-1);
- a pre-fund `takeForOnBehalf` pins `spender` (I-2) and takes a floor (I-6);
- a dual-shape contract carries both data-space guards (I-3);
- a pull `makeOnBehalf` opens `data` with an `address`/dynamic struct, or is added
  to `WORD0_EXEMPT` with the reason (I-4);
- every `uint160(X)` feeding a pull is `Narrow160.to160`, `amount`/`forAmount`, or
  added to `NARROW_EXEMPT` with the reason `X <= 2^160` (I-5).

If the module holds a balance and exposes a permissionless entrypoint, it needs the
sweep (I-7) and the borrow/withdraw/native measured-delta guards (I-8/9/10) — and it
should grow a test named in §2 so the obligation is visible, not remembered.
