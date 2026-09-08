# @1delta-x/modules-fluid

Fluid (Instadapp Vault protocol) lending adapters for `Settlement`. Each
contract is a thin, stateless adapter that performs Fluid actions (deposit,
repay, borrow, withdraw, and fused open/close) on the order maker's behalf when
Settlement processes an order item. The modules live in [`src/`](src/); the fork
tests in [`test/`](test/).

This package is the Fluid sibling of
[`@1delta-x/modules-aave-v3`](../aave-v3) /
[`@1delta-x/modules-morpho-blue`](../morpho-blue). The plug-in shape (MAKE /
TAKE, Permit3 token + taker gates, post-fill invariants) is identical; below we
only cover **what Fluid does differently** — and, in the final section, the
design for extending the package to Fluid's **smart vaults (T2 / T3 / T4)**,
including how the LP split on a smart side is configured.

## What Fluid changes vs. Aave / Morpho

Three Fluid facts shape every module here:

1. **One entrypoint, one health check.** Every position mutation flows through
   `operate(nftId, newCol, newDebt, to)`, which applies a collateral leg and a
   debt leg and runs a **single** health check at the end. Fusing supply+borrow
   (or payback+withdraw) into one `operate` is the architectural payoff — the
   fused modules exist to collect it.
2. **Funding spender is the vault.** Supply/payback tokens are pulled by the
   vault's `liquidityCallback` as `transferFrom(operateCaller → Liquidity)`, so
   the module approves the **vault**, never the Liquidity layer. Supply and
   payback are **permissionless** (no owner check) ⇒ MAKE modules need no NFT
   grant, only a Permit3 token allowance.
3. **Value-out is strict-`ownerOf`.** `operate` authorises borrow/withdraw with
   `VAULT_FACTORY.ownerOf(nftId) != msg.sender` ⇒ revert, and **never consults
   ERC721 approvals**. A module can only borrow/withdraw if it *is* the owner,
   so the TAKE modules do **just-in-time custody**: `transferFrom(maker →
   module)` → `operate(… to = receiver)` → `transferFrom(module → maker)` in one
   call. This needs a one-time `factory.setApprovalForAll(module, true)` from
   the maker — the Fluid analogue of Aave `approveDelegation` / Morpho
   `setAuthorization`, but factory-wide (it covers all the maker's positions;
   the Permit3 amount gate + the `nftId` pinned in `data` bound each op).

| | Aave v3 | Morpho Blue | Fluid |
|---|---|---|---|
| Position key | pool + asset | `keccak256(MarketParams)` | vault + position **NFT id** |
| Borrow / withdraw auth | `approveDelegation` / aToken pull | `setAuthorization` | `setApprovalForAll` + **JIT NFT custody** |
| Funding spender | pool | singleton | the **vault** (not Liquidity) |
| Legs per call | one | one | **two** (col + debt), one health check |
| Full close | repay caps at debt | repay by shares | `type(int256).min` sentinel (`FLUID_ALL`) |

Two package-specific sharp edges:

- **`nftId == 0` mints.** Fluid treats id 0 as "open a fresh position" and
  mints it to `msg.sender` — the module. The single-op modules **reject** it
  (`FreshPositionUnsupported`): they have no hand-off step, so the minted NFT
  (and the collateral inside) would be stranded forever. Opening fresh goes
  through the fused modules, which capture the minted id from `operate`'s
  return value and hand the NFT to the maker in the same call.
- **The `FLUID_ALL` sentinel is uint256-only.** `type(uint256).max` in a `data`
  field maps to Fluid's `type(int256).min` (repay-all / withdraw-all). It does
  **not** fit through `permit3.take`'s uint160 amount, so Permit3-gated legs
  are always exact; "all" only appears on module-funded side legs.

## Authorization: the gates per leg

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance | Permit3 | MAKE legs / fused funding legs — how much of *this token* the module may pull |
| Permit3 **taker** allowance (`ref = keccak256(data)`) | Permit3, TAKE only | how much may be drawn on *this exact vault + nftId (+ op/mode)*; spender-keyed to Settlement |
| `factory.setApprovalForAll(module, true)` | Fluid VaultFactory | which module may take JIT custody — factory-wide, so the narrow Permit3 gates above are what bound each op |

Since `op` / `mode` is part of `data`, borrow-data and withdraw-data hash to
**different** taker refs — the flag can't be flipped to spend a borrow
allowance on a withdraw.

## Modules (`src/`)

All in [`FluidModules.sol`](src/FluidModules.sol); minimal protocol surface in
[`interfaces/IFluid.sol`](src/interfaces/IFluid.sol).

| Contract | Op | Fluid action | Notes |
|---|---|---|---|
| `FluidDepositModule` | MAKE | pull collateral → `operate(nftId, +amount, 0)` | permissionless; rejects `nftId == 0` |
| `FluidRepayModule` | MAKE | pull debt token → `operate(nftId, 0, −amount)` | pull-exact; `amount` must be ≤ live debt (Fluid reverts literal over-payback) |
| `FluidTakerModule` | TAKE | `op=0` borrow / `op=1` withdraw, JIT NFT custody, proceeds → `receiver` | one module address covers both legs of the round-trip under one `setApprovalForAll` |
| `FluidOperateModule` | TAKE | fused **Open** (supply `sideAmount` + borrow) / **Close** (repay `sideAmount` + withdraw) in one `operate` | `sideAmount` in `data` doesn't pro-rate ⇒ **full-fill only** (`FullFillGuard`); Close supports repay-all via `FLUID_ALL` + `repayCeiling` over-pull + residual sweep |
| `FluidTakeForModule` | TAKE_FOR | fused open where the collateral is the core-sized `forAmount` | **partial fills work** on an existing position (one `operate` per slice); `nftId == 0` stays full-fill only — a fresh mint is position *identity*, N slices would mint N positions |

Residual handling is delta-based (`_returnUnused`): a module returns what it
*gained* over the call to the maker — never its whole balance, and never to a
caller-chosen address — and the vault allowance is zeroed when a pull wasn't
fully consumed.

## Smart vaults T2 / T3 / T4 — design (NOT yet implemented)

> Status 2026-09: design only. Verified against the 1delta composer reference
> (`contracts-delegation/contracts/1delta/composer/lending/FluidSmartLending.sol`
> and its T2/T4 fork tests), which already ships smart-vault support.

Fluid's smart vaults replace one or both sides of the position with a **Fluid
DEX LP of two tokens**:

| Type | Collateral | Debt | `operate` shape |
|---|---|---|---|
| T1 | simple | simple | `(nftId, int, int, to)` — this package today |
| T2 | **smart** (2 tokens) | simple | `(nftId, colTok0, colTok1, colSharesMinMax, newDebt, to)` — selector `0x10259f26` |
| T3 | simple | **smart** | `(nftId, newCol, debtTok0, debtTok1, debtSharesMinMax, to)` — **same ABI/selector as T2** |
| T4 | smart | smart | 6 amount params, selector `0x58cc871e` |

Each also has an `operatePerfect` variant denominated in **shares** with
per-token min/max bounds.

### What carries over unchanged

- **One `operate`, one health check** — the fused-open payoff exists
  identically; only arity differs.
- **Funding spender is still the vault** — the composer tests approve the VAULT
  for both smart-side tokens (the DEX-side pull works like the liquidity
  callback). `_pullAndApprove` needs no change.
- **Value-out is still strict-`ownerOf` on the same VaultFactory** — JIT
  custody is unchanged, and because `setApprovalForAll` is factory-wide, a
  grant made for the T1 modules **already covers smart-vault positions**.

### The one impedance mismatch

Module interfaces carry one live fill-sized `amount` (plus one core-sized
`forAmount` for TAKE_FOR); a smart leg has **two token amounts plus a shares
slippage bound**. Fluid itself provides the resolution: smart legs accept
**single-sided** input (one token's delta zero; the DEX rebalances internally,
bounded by `sharesMinMax`) — and everything richer is signable configuration
in `data`.

### Controlling the LP split

`keccak256(data)` is the Permit3 taker ref, so the split policy is
**maker-signed configuration** — a filler can never choose or skew it
(different split ⇒ different ref ⇒ no allowance). Three modes per smart side:

**1. One-sided (slot pick).** `data` pins which token slot receives the live
`amount`; the other slot is 0. Degenerate split; the common "I hold USDC, put
it all in" case.

**2. Fixed ratio (`operate`, both slots).** `data` signs a ratio constant
(`token1PerToken0`, 1e18): slot0 = `amount`, slot1 = `amount × ratio / 1e18`.

- **Pro-rates perfectly** — both slots scale linearly with the fill slice, so
  partial fills keep the exact signed split.
- **Bounded** — the Permit3 gate caps `amount`; the ratio is inside the ref, so
  the token1 pull is implicitly capped at `gate × ratio`. The second token is
  just a second `permit3.transferFrom` (one extra token allowance).
- **Slippage guard as a rate** — `sharesMinMax` must be signed as *min shares
  per unit of `amount`* and scaled per slice (an absolute bound doesn't
  pro-rate). Semantically a limit price on the LP entry: if the pool has
  drifted far enough from the signed ratio that the DEX rebalancing penalty
  eats past the bound, the fill reverts.

**3. Pool-ratio tracking (`operatePerfect`).** For "deposit at whatever the
pool ratio currently is": the live `amount` denominates **shares**, and `data`
carries per-token ceiling *rates* (max token-in per share). Funding amounts are
unknown ex ante, so the module over-pulls both ceilings and sweeps residuals —
the existing Close repay-all pattern (`_returnUnused`, run once per token).
This mode is also the **only** full-exit path on a smart side (see sharp edges
below).

The trade-off is inherent to LP-share collateral, not to this architecture: a
fixed ratio is price-exposed by construction (fills with a bounded shares
penalty, or reverts); perfect mode always matches the pool but gives up split
determinism. The architecture's job is making whichever policy the maker
picked signed, bounded, and slice-safe.

The same three modes apply symmetrically to the **debt side** on T3/T4 borrows
(ratio-split borrow sends both tokens to `receiver`; perfect borrow uses
min-out rates), and to the fused T4 open: `forAmount` = collateral leg with
its own signed split, `amount` = borrow leg with its own — two independent
splits in one `operate` under one health check. The T1 rules keep holding:
`nftId == 0` is full-fill only (position identity); existing positions slice.

### Smart-vault sharp edges

- **No `FLUID_ALL` on smart per-token slots.** Fluid rejects
  `type(int256).min` on per-token smart amounts. Full exit of a smart side =
  `operatePerfect` with `perfectShares = type(int256).min` — the T1
  `_negDelta` sentinel must not be reused on smart slots.
- **Perfect-mode caps' sign follows the *share action*, not token flow.**
  Repaying smart debt burns shares (negative) while tokens flow *in* — the
  per-token caps must be **negative**; positive caps trip
  `VaultDex__InvalidOperateAmount`. (Documented at length in the composer's
  `FluidSmartLending`.)
- **T2 and T3 share one ABI/selector** with different semantics (which side is
  smart). `data` must pin a `vaultType` and the module must place amounts into
  the right slots — a wrong type against a real vault would silently swap the
  collateral and debt legs, so the typed decode dispatches on it explicitly
  (Midnight-style).
- Native funding legs stay out of scope (need `msg.value`); native value-out
  still works via `operate`'s `to_`.

### Implementation plan

Extend `IFluid.sol` with the T2/T3-shape and T4 interfaces (+
`operatePerfect`), then add smart variants of the existing module shapes —
since T2/T3 share an ABI, one smart module per role (not per vault type),
dispatching on `vaultType` in `data`:

| Module | Role | Sketch |
|---|---|---|
| `FluidSmartDepositModule` | MAKE | one-sided / ratio deposit into a smart-col vault; T3 deposit is the T1 shape at 5-param arity |
| `FluidSmartTakerModule` | TAKE | one-sided / ratio borrow & withdraw, JIT custody unchanged |
| `FluidSmartOperateModule` | TAKE | fused open/close incl. perfect-mode full exit (two-token residual sweep), full-fill only |
| `FluidSmartTakeForModule` | TAKE_FOR | fused open, core-sized collateral, partial fills on existing positions, per-slice shares-rate bounds |

The genuinely new arithmetic is small: (1) the shares-bound-as-rate scaling for
partial fills, (2) the perfect-mode ceiling over-pull with two-token sweep and
sign-correct caps.

## Tests

Forked Ethereum mainnet against the composer's real ETH-USDC T1 vault
(`0x0C8C…6cB3`) + VaultFactory (`0x324c…Bf2d`), opening real positions via
direct `vault.operate`. The harness
([`test/shared/FluidModulesBase.t.sol`](test/shared/FluidModulesBase.t.sol))
extends the core `CoreSettlementBase`.

```
pnpm --filter @1delta-x/modules-fluid test
# or, from the repo root:
forge test --match-path 'packages/modules/lending/fluid/**'
```

| Test | What it proves |
|---|---|
| [`integration/FluidLending`](test/integration/FluidLending.t.sol) | pull-exact repay; borrow & withdraw under JIT custody (incl. native collateral out); fused full close (repay-all + withdraw + residual sweep) |
| [`leverage/Leverage`](test/leverage/Leverage.t.sol) | fused deposit+borrow open through a full settlement fill, incl. the partial-fill rejection |
| [`leverage/TakeForOpen`](test/leverage/TakeForOpen.t.sol) | TAKE_FOR open: partial fills slice an existing position (one `operate` per slice), fresh-open stays full-fill only, balance-funded no-conversion shape |
| [`security/TakerModuleAuth`](test/security/TakerModuleAuth.t.sol) | `OnlyPermit3` on every taker module — load-bearing under the factory-wide `setApprovalForAll` |
| [`security/FreshPosition`](test/security/FreshPosition.t.sol) | `nftId == 0` rejection on single-op modules; guard ordering; the stranding it prevents |
