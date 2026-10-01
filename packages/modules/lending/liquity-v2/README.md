# @1delta-x/modules-liquity-v2

Liquity V2 CDP adapters for `Settlement`. Troves are ERC-721 sub-accounts under a
per-branch `BorrowerOperations`. Depends on `@core`.

Fork coverage is **per fork, verified, not assumed**:

| Deployment | Modules | Verified |
|---|---|---|
| Liquity V2 (Ethereum) | `LiquityV2*` | mainnet fork suites (`test/fork`, `test/leverage`) |
| Felix (HyperEVM, feUSD) | `Felix*` for repay / borrow / pre-fund repay; `LiquityV2AddCollModule` and `LiquityV2TakerModule` op 1 work verbatim | `test/fork/FelixFork.t.sol` |
| Quill, Nerite, USDaf, … | — | **not probed.** Check the registry's debt-token getter and the `repayBold`/`withdrawBold` selectors on the fork's BorrowerOperations before deploying; a fork that kept the canonical names uses `LiquityV2*` directly, one that renamed them needs a `Felix*`-style subclass (`_debtToken`, `_repayDebt`, `_withdrawDebt`). |

Felix renamed the BOLD surface: its registry has `feUSDToken()` (no
`boldToken()`), and its BorrowerOperations has `repayfeUSD` / `withdrawfeUSD`
instead of `repayBold` / `withdrawBold`. `FelixModules.sol` overrides exactly
those seams; every safety property is inherited.

## Why Liquity V2 fits — per-trove managers map onto MAKE/TAKE

- **Value-in (addColl, repayBold) is permissionless while the trove's add-manager
  slot is EMPTY.** Liquity keeps **one** add manager per trove
  (`addManagerOf[troveId]`), and the pull-funded `LiquityV2AddCollModule` and
  `LiquityV2RepayModule` are separate contracts, so naming one locks the other
  out. Either leave the slot unset (all value-in modules work), or point it at
  the merged `LiquityV2PreFundModule`, which serves both value-in ops from one
  address.
- `setRemoveManagerWithReceiver(troveId, module, module)` authorises the **TAKE**
  legs (withdrawColl, withdrawBold) and routes the proceeds to the module, which
  forwards them to the order `receiver`. **The receiver must be the module.** The
  2-argument `setRemoveManager(troveId, module)` sets the receiver to the owner;
  and the manager/receiver pair survives a TroveNFT transfer (no hook — wiped only
  on close or liquidation), so a **bought trove must be re-onboarded**.

The value-out ops carry no receiver, so the taker module **measures** what landed
and **reverts (`ShortWithdraw`) if it is less than `amount`** — a missing grant, a
stale or mis-set receiver — then forwards exactly `amount`, sweeping any excess to
the maker. (Without the bound, a stale receiver let the venue pay a third party
while Settlement billed the leg to the maker's wallet — 2026-09-30 audit,
G-VENUE_B-1.)

## Modules (`src/`)

`branchIndex` is resolved through the **immutable** `CollateralRegistry` fixed at
construction (never an address from `data`); every token named in `data` is pinned
to that registry (`boldToken()`/`feUSDToken()` for the debt token, `getToken(index)`
for collateral) and a mismatch reverts `BoldTokenMismatch` / `CollTokenMismatch`.

| Contract | Op | Action | `data` |
|---|---|---|---|
| `LiquityV2AddCollModule` | MAKE | pull collateral → `addColl` | `abi.encode(branchIndex, troveId, collateralToken[, deadline, v, r, s])` — base 96 |
| `LiquityV2RepayModule` | MAKE | read debt → pull `min(amount, debt)` → `repayBold`; the venue clamps the burn at `entireDebt − MIN_DEBT`, residual swept to the maker | `abi.encode(branchIndex, troveId, boldToken)` |
| `LiquityV2TakerModule` (op 0) | TAKE | `withdrawBold` → forward → receiver | `abi.encode(uint8(0), branchIndex, troveId, boldToken, maxUpfrontFee, totalAmount)` — `totalAmount` (the item's full signed amount) is **mandatory**; `maxUpfrontFee` is pro-rated by it |
| `LiquityV2TakerModule` (op 1) | TAKE | `withdrawColl` → forward → receiver | `abi.encode(uint8(1), branchIndex, troveId, collateralToken)` |
| `LiquityV2PreFundModule` | MAKE (pre-funded) | ONE contract, two ops selected by descriptor bits [244,252): `Op.AddColl` — `addColl` the core-delivered leg from the module's own balance; `Op.Repay` — `repayBold(min(forAmount, debt))` from its own balance, venue clamps at `entireDebt − MIN_DEBT`, surplus swept to the maker. Rides the MAKE seam, not `TAKE_FOR` | `abi.encode(forDesc, branchIndex, troveId, collateralToken \| bold)` — descriptor word first, op in its bits |
| `FelixRepayModule` / `FelixTakerModule` / `FelixPreFundModule` | as above | the same, driving `repayfeUSD` / `withdrawfeUSD` and pinning to `feUSDToken()` | identical layouts |

Over-sized repays fill: Liquity v2 **clamps** a `repayBold` above
`entireDebt − MIN_DEBT` rather than reverting, so "repay down to the minimum" can
be signed with headroom on both the pull and the pre-fund repay; the un-burned
amount comes back. Zeroing the debt is `closeTrove` (not wired). A trove already at
or below `MIN_DEBT` rejects every repay inside the venue.

The pre-fund module (`LiquityV2PreFundModules.sol`) is the one-sided "add/repay
whatever the conversion delivered" shape: the maker routes the signed output leg
to the module (`recipient = module`), so the DELIVERED asset needs no ERC20
approval and no Permit3 token allowance. It keeps the registry-rooted
`LiquityV2TroveAuth` ownership binding.

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| addColl / repay (pull) | none while the add-manager slot is empty (recommended); a slot naming one pull module locks the other out | token allowance on collateral / BOLD (module) |
| addColl / repay (pre-fund) | none while the slot is empty, or `setAddManager(troveId, preFundModule)` | none (delivery-funded) |
| borrow / withdraw | `setRemoveManagerWithReceiver(troveId, takerModule, takerModule)` — receiver **must** be the module | taker allowance (Settlement, `keccak256(data)`) |

The taker module enforces `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Caveats

- **Never open troves through the official zappers** — they salt the id *and*
  install themselves as add/remove manager, capturing the trove. Open with a plain
  `openTrove(..., addManager = address(0) | preFundModule, removeManager = takerModule,
  receiver = takerModule)` (a Level-B open module is a planned addition; the
  collateral-side gas compensation needs dedicated handling).
- After **buying** a trove, re-run `setRemoveManagerWithReceiver(troveId,
  takerModule, takerModule)` — the seller's pair survives the transfer. A stale
  receiver now makes the TAKE legs revert rather than paying the seller.
- Gas compensation is collateral/WETH-side (pulled at open, refunded at close);
  the upfront borrow fee applies on open and every debt increase
  (`maxUpfrontFee` guard on `withdrawBold`).

## Tests

`test/unit` and `test/security` run without a fork (the unit mock models the single
add-manager slot and the `MIN_DEBT` repay clamp). `test/fork` and `test/leverage`
fork Ethereum mainnet at block 25.6M (public RPC list in `CoreSettlementBase`,
override with `ETH_RPC_URL`); `test/fork/FelixFork.t.sol` forks HyperEVM
(`https://rpc.hyperliquid.xyz/evm`, override with `HYPEREVM_RPC_URL`).

```
FOUNDRY_PROFILE=modules-liquity-v2 forge test --root ../../../..
```
