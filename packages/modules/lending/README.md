# Lending modules — coverage & wireability

Index of every lending adapter for `Settlement`, and the verdict for the lenders
that **cannot** be wired. Each package is a set of **single-op MAKE/TAKE modules**
that act on the order maker's position on their behalf; per-package detail lives
in each `<lender>/README.md`.

## The mechanic (one paragraph)

A maker signs one `Order` carrying `Item[]`. Settlement walks the items:
**MAKE** = value-in (deposit/repay) — the module pulls the funding token from the
maker via Permit3 and pushes it into the lender; **TAKE** = value-out
(borrow/withdraw) — Settlement routes through `permit3.take` (amount-gated on
`ref = keccak256(data)`), then the module runs the lender call and proceeds land
at `receiver`. `module` + `data` are inside the maker's EIP-712 hash, so a solver
can never repoint which pool/asset is touched or how much.

## Funding shapes — PRE-FUND is the default

Funding source and item op are **two independent axes**, and conflating them is
what the 2026-09 rework fixed:

|  | value IN only | value OUT only | both |
| --- | --- | --- | --- |
| **PULL** (maker's wallet, via `permit3.transferFrom`) | `MAKE` — the plain deposit/repay modules | — | `TAKE_FOR`, maker-addressed leg |
| **PRE-FUND** (the module's own balance) | `MAKE` + `(5 << 253)` descriptor — the `*PreFundModule` contracts | — | `TAKE_FOR`, module-addressed leg |

The op says which way value moves for the user; the descriptor says where the
module's funding comes from. A taker allowance is required exactly when value
leaves the position — which is why the 15 one-sided `*PreFundModule` contracts need
none at all.

Pre-funded is the canonical shape: any flow where the funding leg arrives from a
conversion —
loops, cross-asset opens, deleverage, swap-and-deposit, swap-and-repay, i.e. the
commonly used shapes — should sign the funding output leg with `recipient = the
module` and use the venue's `PreFund…` module. The core sizes `forAmount` to exactly
that delivered leg (`Base._forSlice` admits the item's own module as the
referenced leg's recipient), so the module supplies from its own balance and the
maker's receive side needs **nothing**: no Permit3 token allowance to the module
and no on-chain ERC20 approval of a token they may never have held. It is also
one ERC20 transfer cheaper per fill (measured −28.6k gas on Aave v3).

The **pull-funded** variants (`…TakeFor…` with a maker-addressed leg, and the
plain MAKE deposit/repay modules) remain for exactly one family: the **plain
deposit / repay / deposit+borrow funded from the maker's own wallet** — no loop,
no conversion — where there is no delivered leg to push and the wallet is the
funding source by definition (the literal and balance descriptor forms).

One-sided pre-fund modules ("deposit/repay whatever the conversion delivered") ride
the same seam with a vestigial take side — see the *Pull-funded vs PRE-FUNDED*
section of [`ITakerForModule.sol`](../../core/src/interfaces/ITakerForModule.sol)
for the convention and the soundness argument, and `aave-v3`'s
`AaveV3PreFundModules.sol` for the reference implementations. For venues with
transferable receipt tokens (aTokens, cTokens, ERC-4626 shares), plain
swap-and-deposit needs no module at all: sign the receipt token as the output
leg.

## The wireability test

A lender is wireable **iff**, for each leg it needs, there is a *grantable
on-behalf primitive* and the position model settles in one atomic fill:

| Leg | Requirement |
|---|---|
| deposit (MAKE) | supply crediting `onBehalfOf` — ~universal |
| repay (MAKE) | repay a third party's debt — usually permissionless |
| withdraw (TAKE) | pull the maker's receipt token via Permit3 **or** an operator/allowance to withdraw to a receiver |
| **borrow (TAKE)** | **the binding constraint** — some grantable operator/delegation/allowance/NFT-custody hook that lets the module incur debt for the maker |

> **The SDK's Matrix C understates this.** That column records what the *SDK
> direct/composer* route authorizes, not the full on-chain surface. The module
> mechanic additionally uses on-behalf primitives it marks unused/absent — Euler
> `setAccountOperator`, Dolomite `setOperators`, Gearbox `setBotPermissions`,
> Fluid NFT-custody. So a ⚠️/❌ there ≠ "can't be driven on the user's behalf."
> (These were corrected in `lending-sdks/LENDING_PROTOCOL_INTERFACES.md`.)

---

## Coverage matrix

Status: ✅ shipped · 🟡 partial (subset of legs) · ⛔ blocked (can't wire) ·
⏭️ skipped.

### Already integrated

| Lender | Pkg | Delegation primitive (module mechanic) | Notes |
|---|---|---|---|
| Aave V2 | [`aave-v2`](aave-v2) | `approveDelegation` (borrow) · aToken approve (withdraw) | ✅ |
| Aave V3 (+ Spark/forks) | [`aave-v3`](aave-v3) | same | ✅ pool-agnostic — forks need no new code |
| Aave V4 | [`aave-v4`](aave-v4) | hub/spoke position-manager | ✅ separate surface |
| Compound V2 (+ forks) | [`compound-v2`](compound-v2) | base: cToken approve (withdraw) | ✅ pool-agnostic |
| Venus | [`venus`](venus) | `updateDelegate` + `enterMarkets` | ✅ Compound-v2 fork w/ borrow delegation |
| Compound V3 (Comet) | [`compound-v3`](compound-v3) | `allow(manager)` (Bulker model) | ✅ |
| Euler V2 | [`euler-v2`](euler-v2) | EVC `setAccountOperator` | ✅ (SDK marks this "unused") |
| Morpho Blue | [`morpho-blue`](morpho-blue) | `setAuthorization` | ✅ |
| Morpho Midnight | [`morpho-midnight`](morpho-midnight) | `setIsAuthorized` | ✅ order-book |
| Fluid | [`fluid`](fluid) | just-in-time position-NFT custody | ✅ T1 (SDK marks ❌); T2/T3/T4 smart-vault design in [`fluid/README.md`](fluid/README.md) |
| Dolomite | [`dolomite`](dolomite) | `setOperators` (local operator) | ✅ (SDK marks ❌) |

### Added in this pass

| Lender | Pkg | Fit | Delegation primitive | Legs shipped |
|---|---|---|---|---|
| Silo v2 | [`silo`](silo) | ✅ clean | debt-share `setReceiveApproval` (borrow) · collateral-share allowance (withdraw) | deposit, repay, borrow, withdraw |
| Exactly | [`exactly`](exactly) | ✅ clean | ERC-4626 share allowance (borrow **&** withdraw) | deposit, repay, borrow, withdraw — floating **and** fixed-maturity |
| Lista DAO | [`lista`](lista) | ✅ clean | Moolah `setAuthorization` (collateral + fixed broker borrow) | supply-collateral, repay, **fixed-term** borrow, withdraw-collateral |
| River (Satoshi) | [`river`](river) | ✅ CDP | diamond `setDelegateApproval` | addColl, repay, borrow, withdrawColl, open (Level-B) |
| Liquity V2 (+ forks) | [`liquity-v2`](liquity-v2) | ✅ CDP | per-trove `setAddManager` / `setRemoveManagerWithReceiver` | addColl, repay, borrow, withdrawColl |
| Gearbox V3 | [`gearbox-v3`](gearbox-v3) | 🟡 mixed | pool ERC-4626 (clean) · credit-account `setBotPermissions`/`botMulticall` (best-effort) | pool deposit/withdraw · credit add-collateral/borrow |
| Teller V2 | [`teller`](teller) | 🟡 partial | permissionless value-in only | deposit, repay |

### Blocked / not built

| Lender | Status | Why |
|---|---|---|
| **Term Finance** | ⛔ | Borrow is a sealed-bid auction (`lockBids`) that clears asynchronously — not a synchronous fill. **No** delegation/operator surface, and repay (`submitRepurchasePayment`) is `msg.sender`-scoped with no `…ForBorrower` variant, so there isn't even a permissionless value-in leg to ship. Structurally incompatible. |
| **Init Capital** | ⏭️ | Deprecated — skipped per instruction. (Would be wireable via the Fluid NFT-custody pattern: position NFT approved to the Flash Aggregator.) |

---

## Per-leg blockers inside the partial packages

Not every leg of a "shipped" lender is wireable — the omissions are protocol
constraints, not gaps:

- **Lista — flex (dynamic) borrow.** `broker.borrow(uint256)` is `msg.sender`-only
  (no `onBehalf`), so it can't be driven by a module. Only the **fixed-term**
  broker borrow (`borrow(amount, termId, user, receiver)`, gated by Moolah
  `setAuthorization`) is delegable.
- **Teller — borrow.** `acceptSmartCommitmentWithRecipient` attributes the loan to
  the forwarder's ERC-2771 `_msgSender`, so a module would become the borrower
  (debt on the module, not the maker). Also gated by a Hypernative oracle firewall
  (`onlyOracleApprovedAllowEOA`) + per-market borrower attestation. Making the
  maker the borrower needs the module installed as a **TrustedMarketForwarder**
  (a market-owner governance action), so it's out of reach of a generic fill.
- **Teller — withdraw.** Per-owner withdrawal cooldown (V1 = two-step burn queue;
  V2/V3 = delay) → not atomically expressible.
- **Gearbox — credit-account side.** Wireable via the bot model, but shipped
  **best-effort/unvalidated** (bot-permission bitmask, credit-account resolution,
  multicall fund-flow). The PoolV3 ERC-4626 supply side is the solid core.

---

## Authorization cheat-sheet (added packages)

| Package | Value-in grant | Value-out grant | Receiver routing |
|---|---|---|---|
| silo | Permit3 token allowance | `setReceiveApproval` (borrow) / `silo.approve` (withdraw) | native (`receiver` arg) |
| exactly | Permit3 token allowance | one `market.approve(module)` (share allowance, both legs) | native |
| lista | Permit3 token allowance | Moolah `setAuthorization(module)` | native |
| river | Permit3 token allowance | `setDelegateApproval(module)` + Permit3 token allowance on the output (sweep) | **Permit3-swept** maker→receiver |
| liquity-v2 | `setAddManager` + Permit3 token allowance | `setRemoveManagerWithReceiver(troveId, module, module)` | forwarded (module measures & sends) |
| gearbox-v3 | Permit3 token allowance (+ `setBotPermissions` for credit) | `pool.approve` (pool) / `setBotPermissions` (credit) | native (pool) / multicall `to=receiver` (credit) |
| teller | Permit3 token allowance | — (no taker legs) | — |

All TAKE modules enforce `msg.sender == permit3`; all MAKE modules enforce
`msg.sender == settlement`. The Permit3 taker book is keyed by **spender =
Settlement**, so a standing taker allowance can't be drained by an arbitrary
caller.

---

## Testing status

Every added package **compiles** under its foundry profile and its **security
gate** test passes (rejects non-Permit3 / non-Settlement callers) — these run
without a fork:

```
FOUNDRY_PROFILE=modules-<pkg> forge test --match-path 'packages/modules/lending/<pkg>/test/security/*'
# <pkg> ∈ {silo, exactly, lista, river, liquity-v2, gearbox-v3, teller}
```

**Still pending an RPC endpoint** (no `rpc_endpoints` configured in
`foundry.toml`): the full fork-based leverage/closing/swap suites, and validation
of the documented per-protocol assumptions —

- **River / Liquity V2** — CDP fund-flow direction (value-in from `msg.sender`,
  value-out to `account`).
- **Lista** — the on-behalf `broker.borrow(amount, termId, user, receiver)`
  signature + its Moolah-auth check against the deployed `LendingBroker`.
- **Gearbox** — credit-account bot bits, account resolution, multicall fund-flow.

Each package README flags its own assumption.

## Related

- SDK-side reference (routes, encoders, delegation): `lending-sdks/LENDING_PROTOCOL_INTERFACES.md`
- Core module interfaces: [`@core/interfaces/IMakerModule.sol`](../../core/src/interfaces/IMakerModule.sol),
  [`ITakerModule.sol`](../../core/src/interfaces/ITakerModule.sol)
- Security model: [`/SECURITY.md`](../../../SECURITY.md)
