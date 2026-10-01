# `@1delta-x/modules-pricing-quotes`

Cosigned-quote [`IPriceModule`](../../../core/src/interfaces/IPriceModule.sol)s —
UniswapX's cosigner, without the trusted party. The cosigner is an immutable of the
instance, any maker may deploy one, any filler may present a quote in `takerData`,
and the quote only ever moves the price *within* the maker's signed band.

| | |
|---|---|
| `CosignedQuotePriceModule` | a pinned bump REPLACES the clock. ⚠ `FALLBACK_BPS` is not maker protection — `takerData` is filler-controlled, so an unquoted fill clears at `FALLBACK_BPS` immediately with no decay ramp. Use `0` unless you specifically intend `end` to be always-takeable. |
| `ClockFlooredQuoteModule` | quoted fill → `min(quotedBump, clockBump)`; **unquoted fill → `0` (the maker's `start`)**. The quote is what unlocks the concession and the dutch clock caps it, so the maker never does worse than plain dutch whatever the cosigner signs (absent, buggy, compromised and colluding are all bounded by the clock), and a filler's best response is to present the auction's winning quote. Until audit 2026-09-30 (PRICE-6) an unquoted fill got the clock, which made presenting a quote strictly worse for the filler, so the auction channel did nothing on-chain. Trade-off: with the cosigner offline the order sits at `start` (liveness, not loss). ⚠ `decayDuration == 0` ⇒ ceiling 0 ⇒ no quote can extract anything; sign a window. |

Both verify the same `PriceQuote` type through the same verifier the settlement uses
for makers, so an EIP-1271 cosigner (Safe, passkey wallet) works. The module address
is hashed into the digest, which is what keeps two instances' quotes apart.

**Progress binding (BREAKING typehash, audit 2026-09-30 PRICE-10).** The type is now
`PriceQuote(bytes32 orderHash,address filler,uint256 bumpBps,uint256 deadline,uint256 prevFilled)`
and the digest is `keccak256(abi.encode(TYPEHASH, orderHash, filler, bumpBps, deadline,
prevFilled, chainid, module))`: a quote prices exactly the fill that starts at
`prevFilled` and cannot be replayed on a later partial fill. The 84-byte `takerData`
head is unchanged (`prevFilled` is the core's argument, not the filler's). The
four-argument `quoteDigest` is the `prevFilled = 0` (first fill) case. Neither the
fill SIZE nor the settlement address is bound — see the module NatSpec for why.

```
make test-modules-pricing-quotes
```

> Moved out of `packages/core/src/modules` on 2026-08-24 — see the note in
> [../chainlink/README.md](../chainlink/README.md).

See [docs/pricing-modes.md](../../../../docs/pricing-modes.md) and
[docs/quote-auctions.md](../../../../docs/quote-auctions.md).
