# Open tasks

One numbered file per task (`NN-slug.md`), each with a status / package / severity /
source / opened header and Problem → Change → Acceptance sections. A finished task
is marked `done` in its header and moved to `done/`.

| # | task | kind | status |
| --- | --- | --- | --- |
| 01 | orderbook: taker-permit spenders in the permit-announce path | off-chain fix | done → `done/` |
| 02 | orderbook: Layer-1 recovery with ecrecover semantics | off-chain fix | done → `done/` |
| 03 | ~~[e2e: the app's real market shape against production gates](done/03-e2e-app-market-shape.md)~~ | test | done 2026-10-06 (`staging.sh app-shape`; gates verified — market fills blocked by economics at the 50 bps floor, see Resolution and task 15) |
| 04 | ~~[decide the market order's life (300 s applied)](done/04-market-order-ttl-decision.md)~~ | decision | done 2026-10-06 (300 s confirmed) |
| 05 | ~~[direct-path SELL forgoes the decay — accept or reclaim](done/05-direct-path-decay-decision.md)~~ | decision | done 2026-10-06 (option 3: live `amountOutOffset` on still-decaying direct SELLs) |
| 06 | ~~[solver: typed-callback `onFill`](done/06-solver-typed-callback.md)~~ | contract | done 2026-10-06 |
| 07 | ~~[core: self-sufficient PRESEND bound (B-1)](done/07-core-b1-presend-bound.md)~~ | contract (core) | done 2026-10-06 |
| 08 | ~~[core: `minBumpBps` on `fillWithCallback`](done/08-core-fillwithcallback-minbump.md)~~ | contract (core) | done 2026-10-06 |
| 09 | filler runtime follow-ups | off-chain | done → `done/` |
| 10 | ~~[docs: label the gas figures](done/10-docs-gas-figures.md)~~ | docs | done 2026-10-06 |
| 11 | ~~[Lista SmartTaker: tie the LP-unit item to the coin-unit leg](done/11-lista-smart-taker-unit-split.md)~~ | module + lens | done 2026-10-06 |
| 12 | ~~[Exactly: non-zero floor on a pre-maturity fixed withdraw](done/12-exactly-fixed-withdraw-floor.md)~~ | module + lens | done 2026-10-06 |
| 13 | ~~[module library liveness notes](done/13-module-lib-liveness-notes.md)~~ | lib / lens / docs | done 2026-10-06 |
| 14 | ~~[shapes checker: rule 9 per branch](done/14-shapes-checker-per-branch.md)~~ | tooling | done 2026-10-06 |
| 15 | ~~[app market orders unprofitable at the 50 bps floor](done/15-market-floor-economics.md)~~ | decision | done 2026-10-06 (fee-net ladder + 5 bps stable haircut, 0 min profit; e2e passes) |

Sources: `../REVIEW-2026-10-05-amount-mismatch.md` (03–14),
`../SIGNATURE-VALIDATION-REVIEW.md` (01–02).
