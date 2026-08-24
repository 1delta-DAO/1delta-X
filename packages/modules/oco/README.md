# `@1delta-x/modules-oco`

`OcoGroupModule` — one-cancels-other brackets that survive **partial fills**.

A shared nonce already gives you OCO for whole-fill orders and needs no module at
all. This is the answer when that is too blunt: it is both halves of a bracket in one
contract — an `IOrderValidator` that reads `claim[maker][groupId]` (a `staticcall`, so
it costs a fill nothing when the group is untouched) and an `ISettlementModule` SETTLE
item that writes it. The first leg to fill claims the group; every sibling then fails
closed, including on the winner's second and later partial fills.

`claim` stores `nonce + 1`, so zero can mean "unclaimed" while an order with
`nonce == 0` is still a valid group member.

The `GroupClaimed` event is the one an indexer wants: it retires N−1 bracket siblings
from an off-chain book on a single log, with no RPC and no failed fill to prove it —
see [`packages/orderbook`](../../orderbook/README.md).

```
make test-modules-oco
```

> Moved out of `packages/core/src/modules` on 2026-08-24 along with every other
> module. It is the one that holds STATE, and its lifecycle is fully independent of
> settlement.

See [docs/oco.md](../../../docs/oco.md).
