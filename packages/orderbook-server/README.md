# @1delta-x/orderbook-server

Demo **centralized orderbook backend** for `Settlement` — the "obvious"
centralized fill of the order-distribution slot, ahead of the decentralized
[Waku transport](../../docs/waku-orderbook.md). It is a thin Fastify REST +
WebSocket access layer over [`@1delta-x/orderbook`](../orderbook)'s verified
`Book`: it plays the design doc's **infra node** (an in-memory Relay+Store bus),
and the HTTP/WS surface lets browser makers/fillers that can't run a relay talk
to it. Protobuf on the wire throughout; the chain stays the source of truth.

**Going P2P is one line:** the backend runs its `Book` over an
`InMemoryTransport`; a Waku deployment runs the same `Book` over a
`WakuTransport`. The routes, verification, and wire format are unchanged.

## Endpoints

| Method | Path | Body / query | Response |
|---|---|---|---|
| POST | `/orders` | protobuf `OrderAnnounce` | `202 {orderHash}` or `422 {error}` |
| GET | `/orders` | `?maker=&tokenIn=&tokenOut=&side=` | protobuf `OrderList` |
| GET | `/orders/:hash` | — | protobuf `OrderAnnounce` / `404` |
| POST | `/cancels` | protobuf `SoftCancel` | `202 {evicted}` / `403` (bad signature) |
| POST | `/replaces` | protobuf `OrderReplace` | `202 {orderHash, replaces}` / `422` |
| GET | `/stream` | WebSocket | `SNAPSHOT` then live `ADD` / `CANCEL` / `REPLACE` frames |
| GET | `/health` | — | `{chainId, settlement, permit3, lens, orders}` |

Ingest runs the two-layer self-authenticating pipeline (local recover + deadline,
then one `SettlementLens.getOrderRelevantStates` view call — see the
[library README](../orderbook/README.md)). A rejected order never enters the book;
a junk order that somehow slips through just makes `fill()` revert on-chain.

## Run

Contracts are deployed separately (`packages/core/script/Deploy.s.sol` is a stub).
Point the backend at whatever you deployed. The service runs via `tsx`, which
executes the TypeScript source directly — matching the workspace's
bundler-consumed setup (`moduleResolution: bundler`, same as the SDK), so no
server build step is needed, only the library's `dist`:

```bash
pnpm --filter @1delta-x/orderbook build          # the server imports the built library

CHAIN_ID=31 \
SETTLEMENT=0x… PERMIT3=0x… LENS=0x… \
RPC_URL=https://public-node.testnet.rsk.co \
PORT=8080 \
pnpm --filter @1delta-x/orderbook-server start    # tsx src/bin.ts
```

| env | required | default |
|---|---|---|
| `CHAIN_ID` | ✓ | — (Rootstock testnet = 31) |
| `SETTLEMENT` / `PERMIT3` / `LENS` | ✓ | — |
| `RPC_URL` | ✓ | — |
| `PORT` / `HOST` | | `8080` / `0.0.0.0` |
| `DEFAULT_FILLER` | | zero address (open filler) |

## End-to-end demo

```bash
# 1. start the backend (above), then:
MAKER_PK=0x… TOKEN_IN=0x… TOKEN_OUT=0x… AMOUNT_IN=1000000 \
CHAIN_ID=31 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
pnpm --filter @1delta-x/orderbook-server example:maker    # signs + publishes one order

CHAIN_ID=31 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
pnpm --filter @1delta-x/orderbook-server example:filler   # runs a live Book, prints the order
```

The maker must hold `TOKEN_IN` and have approved Permit3 for it, or Layer 2
reports 0 fillable and rejects the order (422) — the backend only books orders a
solver could actually fill.

## Test

```bash
pnpm --filter @1delta-x/orderbook-server test   # REST + WS over an in-memory bus, stub verifier
```
