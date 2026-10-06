# 02. Recover Layer-1 signatures with ecrecover semantics

- **Status:** done (2026-10-06)
- **Package:** `packages/orderbook`
- **Severity:** low, liveness and book hygiene only. No on-chain authorization is affected.
- **Source:** [SIGNATURE-VALIDATION-REVIEW.md](../../SIGNATURE-VALIDATION-REVIEW.md), findings F2 and F3
- **Opened:** 2026-10-06

## Problem

Both Layer-1 recoveries in the orderbook verifier
([verify.ts:245](../../packages/orderbook/src/verify.ts#L245) for permit announces,
[verify.ts:264](../../packages/orderbook/src/verify.ts#L264) for order announces) use
viem's `recoverTypedDataAddress`. viem 2.54.3 normalises the last signature byte
through `toRecoveryBit`, which accepts `0`, `1`, `27` and `28`. The settler's
`SignatureVerification.tryRecoverSigner` passes `v` straight to `ecrecover`, which
returns `address(0)` for `0` or `1`, so Permit3 and Settlement reject those
signatures.

Two consequences:

- **F2.** On the permit path Layer 2 trusts Layer 1 for the signature
  ([verify.ts:608](../../packages/orderbook/src/verify.ts#L608) sets
  `isSignatureValid: true`), so a permit announce whose signature carries a
  yParity-style `v` is admitted and reported `Fillable` on every sweep until it
  expires. Fillers simulate and fail. A wallet that emits `v = 0/1` in 65-byte
  form hits this in practice. The order path is not affected because Layer 2 still
  gates on the lens's `isSignatureValid`.
- **F3.** The permit path requires exactly 65 bytes
  ([verify.ts:235](../../packages/orderbook/src/verify.ts#L235)), while Permit3
  accepts 64-byte EIP-2098 signatures. A maker signing compact permits is kept out
  of the book although the settler would fill.

Confirmed by a throwaway test: a maker-signed permit witness with its last byte
rewritten from `0x1b` to `0x00` returns `ok: true` from `verifyAnnounce` against a
lens that reports the signature invalid. The identical rewrite on an order-path
announce is rejected with `"invalid signature"`.

## Change

The soft-cancel verifier already has the right primitive: `recoverEcdsa` in
[cancels.ts:219](../../packages/orderbook/src/cancels.ts#L219) accepts 64 and 65
bytes, enforces `v ∈ {27, 28}`, and returns `signer: undefined` where `ecrecover`
would return the zero address.

1. In `verifyLayer1`, replace both `recoverTypedDataAddress` calls with
   `recoverEcdsa(hashTypedData(typedData), sig)`, using
   `permitWitnessTypedData(...)` for the permit path and `orderTypedData(...)`
   for the order path.
2. Permit path: replace the `sig.length !== 132` test with the `standardLength`
   result from `recoverEcdsa`, so 64-byte signatures are verified rather than
   refused. Keep refusing non-standard lengths on this path (a 1271 maker's
   permit cannot be judged off-chain, and the lens cannot see it).
3. Order path: a `recoverEcdsa` result with `standardLength` and no signer means
   `ecrecover` would yield the zero address. Treat it as "does not recover" rather
   than deferring to the lens; the lens would answer the same and it saves a call.
4. Move `recoverEcdsa` out of `cancels.ts` into a small shared module if importing
   it from there reads oddly. Do not duplicate it.

## Acceptance

- Permit announce, 65-byte signature with `v = 0` or `v = 1`: rejected at Layer 1
  with `"permit signature does not recover"`.
- Permit announce, 64-byte compact signature from the maker: admitted
  (`permit: true`). Build it with viem's `signatureToCompactSignature` +
  `compactSignatureToHex`, already used in `test/audit20260930.test.ts`.
- Order announce, 65-byte signature with `v = 0`: rejected at Layer 1 with
  `"signature does not recover"`.
- Order announce, 64-byte compact signature from the maker: admitted without
  deferring to the lens.
- All existing A-FLEX-2, F29 and hardening tests still pass.
- `cd packages/orderbook && npx tsc -p tsconfig.json && npx vitest run` green.

## Notes

The orderbook-worker wraps this verifier unchanged
(`packages/orderbook-worker/src/do.ts`), so no change is needed there. Re-run its
suite anyway: `cd packages/orderbook-worker && npx vitest run`.
