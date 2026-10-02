# Approval surface per flow — the UX contract

What a maker must have granted, per flow, after the 2026-09 pre-fund-funding
rollout. The unit that matters for UX is the **on-chain transaction**: a
signature (order, Permit3 token/taker permit in the witness batch, an in-call
venue sig replay) costs the maker nothing. An ERC20 `approve` to Permit3 is
**once per token, forever** — it is shared by every order, venue, and flow that
ever pays with that token, the same floor Permit2-based systems have.

Everything in the "proven" column is pinned by a test that **revokes the approvals
claimed unnecessary and asserts them zero before filling**. Most of those tests run
on a mainnet (or L2) fork; the rows say so where a venue's proof is mock-only
(2026-09-30 audit G-VENUE_B-8 / L-ML-7: this column used to call mock-only and
nonexistent tests "fork-proven").

## The flow matrix

| Flow | On-chain approvals | Signature-only | Proven |
|---|---|---|---|
| Swap & deposit / swap & repay | **1** — pay asset → Permit3 (reused forever). **Midnight is the exception**: the venue gates `supplyCollateral` and `repay` on `isAuthorized`, so the maker must also `setIsAuthorized` the pre-fund module (and the supply/repay modules and `MidnightLoopCallback` for those flows) — a grant that is full position control, re-delegation included (L-ML-1) | order + the Permit3 pay-asset allowance (one `fillWithPermit` witness batch). The pre-fund modules ride the MAKE seam: **no taker grant** | fork: aave-v2/v3/v4, compound-v2/v3, venus, silo, exactly, liquity-v2, lista, morpho-blue, river `PreFundOneSided` tests; gearbox pool `test_audit_L_LRG_5_poolPreFundDeposit_live` (`test/fork/AuditPoolLegsFork.t.sol`). Mock only: midnight `MidnightPreFundOneSidedTest` (its auth gate is fork-proven on Base by `test/fork/MidnightBaseFork.t.sol`), teller `test/unit/TellerPreFundModules.t.sol` (the repay clamp is fork-proven by `test/fork/TellerRepayClampFork.t.sol`) |
| Borrow → swap (borrowed asset converted, output pushed to maker) | **0** token approvals; venue borrow authority (see channel table). Aave **v2** needs an on-chain `approveDelegation` (v2 debt tokens have no `delegationWithSig`) | taker allowance; delegation is sig-replayed in-call on Aave v3, Comet, Morpho Blue, Lista | borrowed asset flows protocol → Settlement → solver; output legs are pushed — no receive-side grant exists to give |
| Withdraw → swap | **1** — on Aave v2/v3 a **direct aToken ERC-20 approval to the withdraw module** (not to Permit3; `lockdownAll` does not revoke it, the taker-book allowance still gates every pull), **0 on Aave v3** when the aToken EIP-2612 block (spender = the module) is replayed in-call; cToken/share receipts → Permit3; 0 on operator venues whose grant is signable (Comet `allowBySig`, Morpho/Lista `setAuthorizationWithSig`, Exactly share `permit`) | taker allowance | deleverage test (aave-v3); Aave v2 Exact/Full `test_audit_L_AAVE_5_exactWithdraw_live` / `test_audit_L_AAVE_5_fullWithdraw_live` |
| Loop open with margin (equity X, borrow A, collateral B) | **1** — X → Permit3; plus the venue borrow authority | everything else — the X→A→B test settles with ONE maker signature total | `test_oneSignature_crossAssetOpen_XtoAB_onlyXApproved` |
| Loop close with refund (withdraw → swap → repay; surplus refunded) | **1** — receipt asset → Permit3 (or 0, per the withdraw row) | taker allowances for withdraw + repay | `test_preFundDeleverage_onlyThePositionAssetIsApproved`; surplus (leftover collateral, or overshoot when swapping all collateral to the debt currency) is **pushed/swept** — the refund leg needs no grant by construction |

This meets the target contract exactly:

- swap & deposit/repay → only the pay asset;
- borrow/withdraw & swap → only the lender authority;
- loop open with margin → pay asset + borrow authority;
- loop close with refund → only the lender withdrawal authority.

On several venues it is **better** than the target, because the "lender
authority" itself is a signature: Aave v3 (`delegationWithSig`), Compound v3
(`allowBySig`), Morpho Blue and Lista (`setAuthorizationWithSig`) and Euler (EVC
`permit`) are replayed in-call from the item's own signed data
({DelegationHelper}), and Aave v3 aToken pulls can ride an EIP-2612 block — those
flows are **zero on-chain transactions** end to end (beyond the once-ever
pay-asset approve). Aave **v2** is not among them: its debt tokens have no
`delegationWithSig`, and `AaveV2BorrowModule` replays nothing (2026-09-30
G-VENUE_B-7 / L-AAVE-4).

⚠ **A replayed signature SETS a grant, it does not raise it** (2026-09-30 L-LIB-4).
EIP-2612 `permit` and Aave `delegationWithSig` overwrite the allowance with the
signed value, so the helpers skip the replay when the standing grant already covers
the fill; append the optional trailing `signedValue` (the item total) to make a
permit or delegation usable across partial fills. The boolean grants (Comet
`allow`, Morpho/Lista authorization, EVC operator) are permanent and unscoped once
installed. A published venue signature stays landable by anyone until its venue
deadline, even after the order is cancelled; a plain revoke does not consume its
nonce (see [gasless-permit-relay.md](gasless-permit-relay.md) and SECURITY.md).

## Venue authority channels (the value-out grant, and whether it signs)

| Venue | Grant | Signable today |
|---|---|---|
| Aave v2 | `approveDelegation` per debt token | on-chain `approveDelegation` only (no `delegationWithSig` on v2 debt tokens) |
| Aave v3 | `approveDelegation` per debt token | ✅ `delegationWithSig` replayed in-call (`AaveV3CreditModule`) |
| Aave v4 | spoke-wide `setUserPositionManager` **plus** a per-(spoke, reserveId, spender = module) `TakerPositionManager.approveWithdraw` / `approveBorrow` allowance — the grant that actually scopes what the module may take; `Full` withdraws need `approveWithdraw` ≥ the live position (max or padded) | the TakerPM grants are signable (`approveWithdrawWithSig` / `approveBorrowWithSig`) but **not replayed in-call** by the modules, so v4 has no zero-transaction borrow/withdraw (L-CV2-6 / L-CV2-3) |
| Compound v3 | `allow(manager)` | ✅ `allowBySig` replayed in-call |
| Morpho Blue | `setAuthorization` | ✅ `setAuthorizationWithSig` replayed in-call |
| Lista (Moolah) | `setAuthorization` | ✅ `setAuthorizationWithSig` replayed in-call (deployed Moolah accepts Morpho's shape verbatim; only the domain VIEW is renamed `domainSeparator()`, an off-chain-signing detail) |
| Euler V2 | EVC `setAccountOperator` + `enableController` + `enableCollateral` | ✅ one EVC `permit` (self-call batch installing all three) replayed in-call from `EulerV2OperatorModule`'s data tail — **both** funding shapes since the merge |
| Dolomite | `setOperators` | on-chain |
| Venus | `updateDelegate` | on-chain |
| Silo | `setReceiveApproval` (borrow) / share approve (withdraw) | on-chain |
| Exactly | `market.approve` share allowance (borrow & withdraw) | ✅ solmate EIP-2612 share `permit` replayed in-call (verified on the live Optimism markets; per-market domain separators, so no cross-market replay) |
| Morpho Midnight | `setIsAuthorized(module, true, maker)` — **full position control, re-delegation included**, and required for **every** Midnight module (value-in too: `supplyCollateral` and `repay` are auth-gated) | on-chain (L-ML-1 / L-ML-8; `test/fork/MidnightBaseFork.t.sol`) |
| Fluid | position-NFT approval (just-in-time custody) | on-chain (ERC-721) |
| River | `setDelegateApproval` — ⚠ gates value-in too | on-chain |
| Liquity v2 | per-trove `setAddManager` / `setRemoveManagerWithReceiver`; add-coll needs none while no add manager is set | on-chain |
| Compound v2 / Gearbox pool | no borrow surface shipped; value-in permissionless | — |
| Teller | no borrow surface shipped. Repay is permissionless (bound to the borrower: `getLoanBorrower(bidId) == maker`). The **pool deposit is Hypernative-firewalled** (`onlyOracleApprovedAllowEOA`): the module must be registered with the SCF oracle as a deploy step, it is not permissionless (L-CMT-7) | — |

## How many ADDRESSES hold the grant (2026-09-10)

The rows above say what a maker must grant. This says how many separate
contracts they must grant it to — a dimension the matrix hid, because a venue
whose authority is one unscoped boolean multiplies that boolean by the number
of module addresses that need it.

Modules are therefore grouped by **the standing grant they consume**, not by
seam or by op:

| Venue | Grant | Addresses before | After |
|---|---|---|---|
| Aave v3 | credit delegation (scoped: one debt token, one cap) | 2 (`Borrow`, `Leverage`) | **1** — `AaveV3CreditModule` |
| Euler v2 | EVC `setAccountOperator` — unscoped boolean, total account control | 4 (taker, batch, takeFor, preFund-takeFor) | **1** — `EulerV2OperatorModule` |
| Dolomite | `setOperators` — unscoped boolean, total account control, and needed for value-IN too | 5 (deposit, repay, taker, operate, takeFor) | **1** — `DolomiteOperatorModule` |

The op moves INSIDE `data`, hence inside `ref = keccak256(data)`, so Permit3's
taker book still separates the per-op, amount-capped allowances exactly as it did
when they were separate contracts. Only the coarse standing flag consolidates —
and that flag was never per-op.

⚠ **The split BETWEEN grant classes is deliberate.** A merged contract redeploys
as a unit, so a bugfix in one op invalidates the grant every other op in that
contract relies on. Aave keeps three addresses because it has three genuinely
different grants (credit line / aToken / wallet allowance) and that boundary buys
real containment. Euler and Dolomite collapse to one because there is no boundary
left to contain: every address already required the identical unscoped flag, so
splitting them bought nothing and cost three or four extra approvals. Copying
Aave's partition to those venues would have been the wrong answer.

Venues already at one address (their `*TakerModule` multiplexes borrow/withdraw
behind a leading `op`): Comet, Morpho Blue, Silo, Venus, Exactly, Liquity v2,
Lista, River.

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

A front-run submission leaves exactly the allowance the fill wants (the same
reasoning as {DelegationHelper}'s best-effort replays), but **only route 1 can
tolerate it**: a solver multicall can wrap `token.permit` in `try/catch`. Routes 2
and 3 run the permit as the callback or a `CALL` step, and the executor bubbles
any failure (`CallbackFailed`), so a front-run permit reverts the whole fill —
those callers must retry without the permit (2026-09-30 X-SPEC-10). The aToken
EIP-2612 block for Aave withdrawals already rides in-module
(`AaveV3WithdrawModule`'s optional permit block; spender = the module).

## Residual venue-grant wiring — DONE (2026-09-03)

- **Euler**: `DelegationHelper.replayEvcPermit` — a dynamic tail after
  `EulerV2OperatorModule`'s 128-byte {OpenData} head carrying
  `abi.encode(EvcPermit[])`: maker-signed EVC `permit`s whose self-call batches
  install operator + controller + collateral in the fill itself, each replayed
  independently. Since 2026-09-30 (L-ED-1) makers sign **`sender =
  EulerV2OperatorModule`**, so a lifted permit can no longer be landed directly or
  front-run at all (the earlier any-sender permit, and the "front-run tolerated"
  note here, are superseded; so is the any-sender design in
  [audit-2026-09-11-grant-merge.md](audit-2026-09-11-grant-merge.md) §8.4). Put the
  long-lived operator grant in its own permit and nonce namespace, apart from the
  per-order controller/collateral enables. Domain/typehash validated against the
  live EVC (the EVC domain has NO `version` field). A fresh maker key opens a
  levered Euler position with their transaction nonce still 0. EVC sub-accounts
  are supported (L-ED-6): the maker grants operator/controller per sub-account,
  and pulls and sweeps stay on the owner wallet.
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

- **Compound v3** (`allowBySig`): wired via `DelegationHelper.replayCometAllow` in
  `CometTakerModule` (borrow @96, Exact withdraw @128, Full withdraw @160);
  fork-proven by `test_audit_L_CMT_5_realCometAllowBySigLandedInFill`.

The remaining on-chain venue grants (Aave v2 `approveDelegation`, Aave v4
`setUserPositionManager` and the TakerPM allowances, Venus `updateDelegate`,
Dolomite `setOperators`, Silo `setReceiveApproval`, Fluid ERC-721, River
`setDelegateApproval`, Liquity trove managers, Midnight `setIsAuthorized`) are
on-chain transactions: either the deployed contract has no signature variant (the
venue's floor, not ours), or, for the Aave v4 TakerPM, the signature variant exists
but no module replays it yet. Pre-fund modules need no taker allowance at all.
