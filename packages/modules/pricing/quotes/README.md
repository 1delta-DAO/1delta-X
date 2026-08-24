# `@1delta-x/modules-pricing-quotes`

Cosigned-quote [`IPriceModule`](../../../core/src/interfaces/IPriceModule.sol)s —
UniswapX's cosigner, without the trusted party. The cosigner is an immutable of the
instance, any maker may deploy one, any filler may present a quote in `takerData`,
and the quote only ever moves the price *within* the maker's signed band.

| | |
|---|---|
| `CosignedQuotePriceModule` | a pinned bump REPLACES the clock. ⚠ `FALLBACK_BPS` is not maker protection — `takerData` is filler-controlled, so an unquoted fill clears at `FALLBACK_BPS` immediately with no decay ramp. Use `0` unless you specifically intend `end` to be always-takeable. |
| `ClockFlooredQuoteModule` | `min(quotedBump, clockBump)` — a quote can only *improve* on plain dutch, never undercut it. Removes the `FALLBACK_BPS` footgun structurally (there is no fallback to misconfigure), which makes the cosigner safe to point at a third party the maker does not fully trust: absent, buggy, compromised and colluding all degrade to an ordinary dutch fill. ⚠ `decayDuration == 0` ⇒ ceiling 0 ⇒ no quote can extract anything; sign a window. |

Both verify the same `PriceQuote` type through the same verifier the settlement uses
for makers, so an EIP-1271 cosigner (Safe, passkey wallet) works. The module address
is hashed into the digest, which is what keeps two instances' quotes apart.

```
make test-modules-pricing-quotes
```

> Moved out of `packages/core/src/modules` on 2026-08-24 — see the note in
> [../chainlink/README.md](../chainlink/README.md).

See [docs/pricing-modes.md](../../../../docs/pricing-modes.md) and
[docs/quote-auctions.md](../../../../docs/quote-auctions.md).
