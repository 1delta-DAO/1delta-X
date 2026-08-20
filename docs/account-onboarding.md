# Account onboarding

*Getting a fresh account ready to be filled: the two grants Permit3 needs, which
of them a signature can create, and why the obvious EIP-7702 answer has no
adoption path.*

Nothing in this document is a new mechanism. It is the map of which existing one
applies to which kind of account — and a record of one approach that was built,
measured against reality, and deleted.

---

## The two legs

Before a maker can be filled, **two** grants must exist per token, and they are
different kinds of thing:

| leg | what it is | can a signature create it? |
|---|---|---|
| `token.approve(PERMIT3, max)` | the ERC20's own allowance — what lets Permit3 call `transferFrom` at all | **only via EIP-2612** |
| `PERMIT3.approveToken(spender, token, …)` | Permit3's book — what decides *who* may spend it | **yes**, always |

Permit3 moves tokens with `SafeTransferLib.safeTransferFrom(token, from, to, amount)`
([`AllowanceTransfer.sol:160`](../packages/core/src/permit3/AllowanceTransfer.sol#L160)),
so the first leg is not optional and not something Permit3 can grant itself.

The second leg already has a complete gasless path:
`permitBatchWithWitnessIfNeeded` inside
[`fillWithPermit`](../packages/core/src/settlement/Core.sol#L154). The maker signs,
the solver relays, and the idempotent variant means a front-run permit does not
brick the order.

**So the whole onboarding problem is the first leg.** Everything below is a way of
closing it.

---

## Route 1 — contract accounts. Already solved.

An account that is a contract can simply make both calls itself.
[`PositionFunnel.enableToken`](../packages/modules/bridge/src/funnel/PositionFunnel.sol)
is that, built in:

```solidity
SafeTransferLib.forceApprove(token, address(PERMIT3), type(uint256).max);
PERMIT3.approveToken(SETTLEMENT, token, type(uint160).max, 0);
```

and `enableTokens(address[])` batches it.

It is **permissionless**, which is the property that matters: a solver wires the
maker while filling, so a user arriving on a chain they have never touched sends
zero transactions. That is safe only because both destinations are immutable —
Settlement can pull nothing except against an order the account signed. A helper
that took the spender as an argument could not be permissionless; see the rejected
approach below, where getting this backwards is a one-call drain.

This covers the case that motivates onboarding most sharply — a bridged user with
no gas on the destination chain — because on that path the account **is** a
funnel. It leaves only the ordinary home-chain EOA.

---

## Route 2 — EIP-2612. The one with real reach.

An EIP-2612 signature creates the ERC20 allowance with no transaction and **no
wallet feature beyond signing typed data**. Every wallet does that today, with no
vendor cooperation required. That is the adoption path the alternatives lack.

### What exists

[`PermitHelper.replayIfPresent`](../packages/core/src/utils/PermitHelper.sol) and
[`IERC2612`](../packages/core/src/interfaces/IERC2612.sol). The permit is appended
as an optional 128-byte tail to a module's `data` and replayed inside the module
call. Encodings, per-module offsets and the best-effort rule are documented in
[gasless-permit-relay.md](gasless-permit-relay.md) — not repeated here.

### The limitation

It is reachable **only through a module that calls `PermitHelper`**. The permit
bytes live inside `data`, which is part of the order hash *and* of
`ref = keccak256(data)` for a TAKE item, so they are frozen into the maker's
authorization. That is also why the replay must stay `try/catch`: a hard revert on
a spent nonce would let anyone kill a gasless order from the mempool for the price
of one cheap transaction.

The consequence is that a plain conversion order — no items, no lending module —
has no way to carry a 2612 permit at all.

### The proposal: lift it to Permit3

A sibling of `permitBatchWithWitnessIfNeeded` that takes 2612 blocks alongside the
batch: replay each (best-effort, same argument as above), then apply the book
grants. Both legs, from signatures only, for any order shape.

It needs **zero Settlement bytecode**, which matters — Settlement runs against
EIP-170 with roughly a hundred bytes of headroom, while Permit3 has room. The
solver makes two calls in its own transaction:

```
solver tx:
  1. permit3.permitBatchWith2612(owner, batch, permits2612, witness, sig)
  2. settlement.fill(order, sig, amount)
```

`fill` is permissionless and a solver's transaction may do anything before it —
the same shape the CCTP path already uses for `receiveMessage` + `fill`.

### Coverage

Not universal. USDC and most modern tokens implement 2612; **DAI** uses the older
`allowed`-style variant and needs a second code path; **WETH** has neither.

---

## Route 3 — EIP-5792 `wallet_sendCalls`. SDK only, no contract.

For tokens with no permit of any kind, ask the wallet to batch
`[token.approve, permit3.approveToken]` as one request. The wallet decides how to
execute it — its own EIP-7702 delegator, its own smart account, or two sequential
transactions.

This is the realistic version of "batch the approvals," because 5792 is the
standard wallets are actually implementing. Adoption is theirs to deliver, not
ours to win, and it requires no contract on our side at all.

---

## Rejected — a bespoke EIP-7702 delegation target / ERC-7579 module

Recorded because it is an appealing idea that does not survive contact with how
wallets work, and it should not be re-proposed without new information.

**The shape.** A small stateless `Permit3Approver` that an EOA points at under
EIP-7702, exposing `enable(tokens)` that loops both legs; plus an ERC-7579
executor module carrying the same payload for smart accounts. Both were written,
tested and deleted (2026-08). The equivalent exists in
[eco/permit3](https://github.com/eco/permit3) as `ERC7702TokenApprover` and
`ERC7579ApproverModule`.

**Why it fails.** Adoption, on both hosts:

- **EIP-7702 delegation targets are chosen by the wallet.** Wallets ship their own
  delegator implementation and will not sign a raw authorization pointing at a
  third-party contract. An EOA delegated *solely* to an approver could also do
  nothing else, since that contract would be its entire code.
- **ERC-7579 module installation is gated by the account vendor**, and for a
  one-time wiring the module is strictly *worse* than the account's own batch:
  installing costs a user operation, and doing the two approvals directly costs a
  user operation. It only pays off for recurring, solver-triggered wiring.

**What was right about it, and is worth keeping in mind.** The value was never
batching — both hosts batch natively. It was the *permissionless trigger*, which a
generic batch executor can never offer, because an open generic executor would let
anyone call arbitrary targets as the account. Only fixed, immutable destinations
make an open entry point safe. That is exactly the trade `PositionFunnel.enableToken`
makes, and it is why Route 1 works.

**The trap, if it is ever revisited.** A `enableFor(spender, tokens)` on a
7702-delegated account must be gated on `msg.sender == address(this)`. Left
permissionless it lets anyone hand an arbitrary address an infinite Permit3
allowance over that account's tokens — a complete drain, in one call, from a
contract whose entire purpose is to look harmless.

---

## Which route applies

| account | route |
|---|---|
| bridged user on a fresh chain | **Route 1** — the account is a `PositionFunnel`; solver calls `enableTokens`, user sends nothing |
| any other contract account (Safe, 7579 account) | its own batch — two calls, one user operation |
| EOA holding a 2612 token | **Route 2** — signature only, once Permit3 carries the replay |
| EOA holding a non-permit token (WETH) | **Route 3**, or the ordinary one-time `approve` |

That last row is worth stating plainly rather than engineering around: one
`approve` per token per chain, once, is the accepted cost of the entire Permit2
model. Onboarding work is worth doing where the user has **no gas at all** — which
is Route 1, and which is already finished.
