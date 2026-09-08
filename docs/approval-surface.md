# Approval surface per flow — the UX contract

What a maker must have granted, per flow, after the 2026-09 pre-fund-funding
rollout. The unit that matters for UX is the **on-chain transaction**: a
signature (order, Permit3 token/taker permit in the witness batch, an in-call
venue sig replay) costs the maker nothing. An ERC20 `approve` to Permit3 is
**once per token, forever** — it is shared by every order, venue, and flow that
ever pays with that token, the same floor Permit2-based systems have.

Everything in the "proven" column is pinned by a fork test that **revokes the
approvals claimed unnecessary and asserts them zero before filling**.

## The flow matrix

| Flow | On-chain approvals | Signature-only | Proven |
|---|---|---|---|
| Swap & deposit / swap & repay | **1** — pay asset → Permit3 (reused forever) | order + Permit3 allowances + pacing taker grant (one `fillWithPermit` witness batch) | aave-v2/v3/v4, compound-v2/v3, venus, silo, exactly, gearbox, lista, morpho-blue, midnight, teller `PreFundOneSided` tests |
| Borrow → swap (borrowed asset converted, output pushed to maker) | **0** token approvals; venue borrow authority (see channel table) | taker allowance; delegation is sig-replayed in-call on Aave v2/v3, Comet, Morpho Blue | borrowed asset flows protocol → Settlement → solver; output legs are pushed — no receive-side grant exists to give |
| Withdraw → swap | **1** — receipt asset (aToken/cToken/share) → Permit3; **0 on Aave v3** (aToken EIP-2612 block replayed in-call) and on operator venues whose grant is signable (Comet `allowBySig`, Morpho `setAuthorizationWithSig`) | Permit3 module allowance + taker allowance | deleverage test (aave-v3) |
| Loop open with margin (equity X, borrow A, collateral B) | **1** — X → Permit3; plus the venue borrow authority | everything else — the X→A→B test settles with ONE maker signature total | `test_oneSignature_crossAssetOpen_XtoAB_onlyXApproved` |
| Loop close with refund (withdraw → swap → repay; surplus refunded) | **1** — receipt asset → Permit3 (or 0, per the withdraw row) | taker allowances for withdraw + repay | `test_preFundDeleverage_onlyThePositionAssetIsApproved`; surplus (leftover collateral, or overshoot when swapping all collateral to the debt currency) is **pushed/swept** — the refund leg needs no grant by construction |

This meets the target contract exactly:

- swap & deposit/repay → only the pay asset;
- borrow/withdraw & swap → only the lender authority;
- loop open with margin → pay asset + borrow authority;
- loop close with refund → only the lender withdrawal authority.

On several venues it is **better** than the target, because the "lender
authority" itself is a signature: Aave v2/v3 (`delegationWithSig`), Compound v3
(`allowBySig`), Morpho Blue (`setAuthorizationWithSig`) are replayed in-call
from the item's own signed data ({DelegationHelper}), and Aave v3 aToken pulls
can ride an EIP-2612 block — those flows are **zero on-chain transactions**
end to end (beyond the once-ever pay-asset approve).

## Venue authority channels (the value-out grant, and whether it signs)

| Venue | Grant | Signable today |
|---|---|---|
| Aave v2 / v3 | `approveDelegation` per debt token | ✅ `delegationWithSig` replayed in-call |
| Aave v4 | `setUserPositionManager` (position state) | on-chain |
| Compound v3 | `allow(manager)` | ✅ `allowBySig` replayed in-call |
| Morpho Blue | `setAuthorization` | ✅ `setAuthorizationWithSig` replayed in-call |
| Lista (Moolah) | `setAuthorization` | ✅ `setAuthorizationWithSig` replayed in-call (deployed Moolah accepts Morpho's shape verbatim; only the domain VIEW is renamed `domainSeparator()`, an off-chain-signing detail) |
| Euler V2 | EVC `setAccountOperator` + `enableController` + `enableCollateral` | ✅ one EVC `permit` (self-call batch installing all three) replayed in-call from the pre-fund module's data tail |
| Dolomite | `setOperators` | on-chain |
| Venus | `updateDelegate` | on-chain |
| Silo | `setReceiveApproval` (borrow) / share approve (withdraw) | on-chain |
| Exactly | `market.approve` share allowance (borrow & withdraw) | ✅ solmate EIP-2612 share `permit` replayed in-call (verified on the live Optimism markets; per-market domain separators, so no cross-market replay) |
| Fluid | position-NFT approval (just-in-time custody) | on-chain (ERC-721) |
| River | `setDelegateApproval` — ⚠ gates value-in too | on-chain |
| Liquity v2 | per-trove `setAddManager` / `setRemoveManagerWithReceiver`; add-coll needs none while no add manager is set | on-chain |
| Compound v2 / Teller / Gearbox pool | no borrow surface shipped; value-in permissionless | — |

## What made this hold

1. **Pre-funding** (`Base._forSlice` admits the item's own module as the
   referenced leg's recipient): every conversion-delivered asset lands at the
   maker-signed module and is consumed at the core-sized amount — the received
   asset never transits the maker's wallet, so no grant for it can even exist.
2. **Output legs are pushed** — the receive side of any swap needs nothing.
3. **Proceeds route protocol → Settlement → solver** — a borrowed/withdrawn
   asset that pays the solver needs no maker grant either.
4. **The witness-bound permit batch** (`fillWithPermit`) folds the pay-asset
   Permit3 allowance and every taker allowance into the order signature.

## Killing the last approve: EIP-2612 pay assets (no protocol code needed)

For a pay asset that implements EIP-2612, even the once-ever ERC20 approve to
Permit3 becomes a signature — with ZERO protocol changes, because
`token.permit(maker, permit3, value, deadline, v, r, s)` is a permissionless
third-party call. The maker signs it off-chain alongside the order; whoever
fills lands it atomically by any of three existing routes:

1. **Solver contract**: multicall `token.permit(…)` then `fill(…)` — the
   standard route for professional fillers.
2. **`fillWithCallback`, `PreDelivery`, untyped**: the callback invokes
   `(target, data)` verbatim, so `target = the token`, `data = the permit
   calldata` lands the approval inside the fill itself — no solver contract
   needed.
3. **`matchSettle`**: a `CALL` step through the executor, scheduled before the
   PULL of that input leg.

The permit is idempotent-adjacent in practice (a front-run submission leaves
exactly the allowance the fill wants — same reasoning as
{DelegationHelper}'s best-effort replays), so route 1/2 callers should tolerate
a reverting permit and proceed. The aToken EIP-2612 block for Aave withdrawals
already rides in-module (`AaveV3WithdrawModule`'s optional permit block).

## Residual venue-grant wiring — DONE (2026-09-03)

- **Euler**: `DelegationHelper.replayEvcPermit` — a dynamic tail block after
  `EulerV2PreFundTakeForModule`'s 128-byte head carrying one maker-signed EVC
  `permit` whose self-call batch installs operator + controller + collateral in
  the fill itself. Domain/typehash validated against the live EVC (note: the
  EVC domain has NO `version` field); front-run of the lifted permit is
  tolerated (best-effort replay, pinned by test). A fresh maker key opens a
  levered Euler position with their transaction nonce still 0.
- **Lista**: the deployed Moolah accepts Morpho's `setAuthorizationWithSig`
  verbatim, so `replayMorphoAuth` is reused unchanged — optional tails on the
  fixed-term borrow and withdraw-collateral ops; front-run tolerance validated
  on the live BSC contract.

- **Exactly** (2026-09-03): the live markets carry solmate's ERC20 `permit`, so
  the share-allowance grant rides an optional 160-byte tail
  (`value, deadline, v, r, s` — the explicit `value` because a 2612 signature
  commits to it; the Market debits SHARES at its own conversion while orders
  are in assets, so `value = the asset total` is the natural over-approximation
  and under-sizing fails closed). Replayed via the new
  `PermitHelper.replayValueIfPresent` (spender = the module, value explicit —
  the existing `replayIfPresent` derives value from the fill amount and could
  not fit). Front-run tolerated; withdraw tails require the `BalanceMode` slot
  to be encoded explicitly so the offset stays unambiguous.

The remaining on-chain venue grants (Aave v4 `setUserPositionManager`, Venus
`updateDelegate`, Dolomite `setOperators`, Silo `setReceiveApproval`, Fluid
ERC-721, River `setDelegateApproval`, Liquity trove managers) have no signature
variant on the deployed contracts — that is the venue's floor, not ours.
