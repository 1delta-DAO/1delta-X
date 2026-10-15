# Native RBTC delivery without capital — plan (2026-10-14)

**Status:** plan. Written after the in-fill unwrap (task 28) turned out to be unfillable by
our zero-capital solver. Supersedes task 28's "inventory or solver v3 with PreDelivery"
options; task 30 tracks the build.

**Broader context:** this is one case of a general ordering flaw. See
[fill-ordering-capital-plan.md](fill-ordering-capital-plan.md) (task 31). After that
core fix, the `NativeUnwrapModule` path also fills with zero capital. `NativeBalance`
remains the cheaper route and the only one that needs no Settlement change.

## 1. The flaw

Native-out was modelled as an **item**: a WRBTC output leg delivered to the
`NativeUnwrapModule`, plus a pre-funded MAKE item that unwraps the delivery and sends RBTC
to the maker. Items only run where Settlement delivers outputs **before** it pays inputs.
Our solver works the other way round.

| Fill path | Order of steps | Items? |
| --- | --- | --- |
| `AggregatorFillSolver.executeFill` → `fillWithCallback(PostInputs*)` | maker pays → solver routes → outputs | **no** (`ReverseModeRequiresNoItems`) |
| `AggregatorFillSolver.executeItemFill` → `matchSettle` | netted plan | **refuses pre-funded MAKE** (the module's shape) |
| plain `fill` / `fillUpTo` | outputs → items → inputs | yes, but the filler must **already hold the WRBTC** |

So **every native fill needed filler capital**: inventory or a flash loan. A flash loan
costs a fee and ~100k+ gas on every fill, which is a no-go on a gas-priced chain where
the whole fill costs ~$0.60. Fork-proven on 2026-10-14 against the live contracts
(`packages/beta-filler/e2e/native-out-fork.sh`).

The industry does not do it this way. In CoW (ETH buy token), 1inch (unwrap flag) and
UniswapX, native delivery is a **delivery mode of the order**, not a post-fill item: the
protocol contract holds the native coin for a moment and **pushes it to the recipient
itself**. Nothing is measured. CoW's solver unwraps WETH into the settlement contract
during its interactions, and the contract pays out after them (§6). Our Settlement cannot
do this without a redeploy: it has no `receive()` and no native path. So `NativeBalance`
(§2) inverts the roles. The solver pushes, and the core measures the receipt.

## 2. The fix: native delivery on DIRECT orders through a balance view

What a DIRECT (delta-verify, timing bit 104) order does with its output token, from
`Core._snapshotOutRecipients` / `_deliverOutputs`:

```
before = balanceOf(token, recipient)      // staticcall, before the solver's callback
… solver's callback delivers out-of-band …
after  = balanceOf(token, recipient)      // staticcall
require(after − before ≥ priced amount)    // DeltaTooLow otherwise
```

Settlement never transfers, approves or otherwise calls the output token on this path.
Both calls are a read-only `balanceOf`. So:

- **`NativeBalance`**: a stateless, ownerless contract with one function,
  `balanceOf(address a) returns (a.balance)`. No `transfer`, `transferFrom` or `approve`.
- An order receiving RBTC signs `legsOut[0] = { token: NativeBalance, amount, recipient: 0x0 (maker) }`,
  DIRECT delivery, `exclusiveFiller = our solver`. This is the app's normal market shape
  with a different token.
- The solver's route ends in WRBTC. In its callback the solver unwraps it
  (`WRBTC.withdraw`) and sends RBTC to the recipient. Settlement measures the
  recipient's native balance going up, unchanged.

Zero capital, no item, no module hop, no flash loan, **no Settlement change, so no
re-approvals**. Extra gas over a plain direct fill is roughly the withdraw plus the native
send (~20–25k), against +100k for the module path (pull +60k, item +40k).

**Measured (2026-10-15).** The real filler ran on a Rootstock fork against the live Settlement,
using `packages/beta-filler/e2e/native-direct-fork.sh`. The figures are receipt gas, so they
include the 21k base and calldata, with refunds applied:

| Fill | Receipt gas |
| --- | --- |
| WRBTC to a maker already holding WRBTC | 226,138 |
| WRBTC to a maker holding none | 243,204 |
| RBTC through `NativeBalance` | 255,880 |

So native delivery costs **+29.7k** over a like-for-like WRBTC fill, and **+12.7k** over the
usual case: a maker buying RBTC holds no WRBTC, so a WRBTC fill pays a new-slot SSTORE that
the native fill does not. At the minimum gas price that is about 0.0000007 RBTC (~$0.06) per
fill. A manual unwrap costs more than that, needs a second transaction, and needs RBTC for
gas. In the unit benches the solver's execution overhead alone is +15.3k
(`AggregatorNative.t.sol`); the live-fork Foundry test measures +27.0k of execution
(`NativeDeliveryRootstock.fork.t.sol`).

### Why it is safe (to be re-checked in review)

- **Fails closed everywhere else.** On any PULL path Settlement would call
  `transferFrom` on `NativeBalance`, which has no such function, so the fill reverts. The
  same goes for using it as an input leg (Permit3 / direct pull) and for
  `DeltaVerifySameToken`. It cannot be anything but a delta-verified output.
- **Inflow attribution** is the same as for any delta-verify order (re-audit F30). Only the
  named `exclusiveFiller` can run the callback, for the order's whole life, so no foreign
  inflow can pass as this delivery.
- **The maker's balance cannot fall during the fill**: the maker is not the tx sender, so
  gas is never charged to them. A contract maker that spends native inside its
  `receive()` lowers the measured delta, and the fill reverts (fail closed). A maker
  whose `receive()` reverts kills the fill (same posture as the module; EOAs cannot revert).
- **Duplicate-leg check** (`DeltaVerifyDuplicateLeg`) works on the `NativeBalance`
  address like any token.
- **Batching:** `matchSettle` already refuses delta-verify orders, so native delivery
  never enters a batch.

## 3. Work items

1. **Contract `NativeBalance`** (periphery, ~20 lines + tests): deploy by plain CREATE,
   ~100k gas ≈ 0.000003 RBTC.
2. **Solver v3** (`AggregatorFillSolver`):
   - immutables `NATIVE_BALANCE` and `WNATIVE`;
   - for a leg in `NATIVE_BALANCE`, the route's last hop pays the solver (not the maker);
     then `WNATIVE.withdraw(amt)` and a full-gas `call{value: amt}` to the recipient;
   - a `receive()` that accepts only from `WNATIVE`;
   - surplus split and retain mode unchanged, in WRBTC;
   - a fork test against the live Settlement.

   Redeploy: ~5.1M gas ≈ 0.00012 RBTC (~$10). The deployer holds ~0.000061 RBTC, so it
   needs a top-up.
   **Migration:** open DIRECT orders name the v2 solver as `exclusiveFiller`. The
   filler must keep driving v2 until they expire (market orders: ≤ 5 min; limit orders: up
   to their 7-day expiry). Make `AGGREGATOR_SOLVER` a list, or keep v2 as a secondary.
3. **Lens / book:**
   - confirm `SettlementLens.validateOrder` / `getOrderRelevantStates` read nothing on
     the output token of a direct order beyond `balanceOf`, and accept the shape;
   - add `NativeBalance` to the book's `ALLOWED_TOKENS`.
4. **Filler:** treat a `NativeBalance` leg as WRBTC for routing and quoting, with the plan's
   last-hop recipient = solver, + `NATIVE_DIRECT_GAS` (learned per shape as `+native`),
   and request `nativeOut` → direct.
   Replaces the module-shape wiring (`nativeOutShape` stays for a future pull/inventory path).
5. **App:**
   - the RBTC entry in the receive dropdown (done, 46ffdd5) signs the DIRECT
     `NativeBalance` shape instead of the module shape;
   - fill tracking reads the maker's native balance;
   - a book fill whose token is `NativeBalance` displays as RBTC.
6. **SDK:** a `NATIVE_BALANCE` constant per chain and a `nativeOutLeg()` helper; a golden
   vector for the shape.
7. **Docs:** FEATURES / SECURITY entries, deployment record, this plan → done.

Native **input** (the maker sells RBTC) stays as it is: the app wraps exactly the shortfall
in one 43k-gas `deposit` before signing (`lib/funding.ts`).

## 4. Alternatives considered

| Option | Capital | Contract change | Verdict |
| --- | --- | --- | --- |
| Module item + flash loan per fill | flash | none | **rejected:** fee + ~100k gas per fill |
| Module item + WRBTC inventory in the operator EOA | float | none | interim fallback only: BTC exposure, a float to manage, pull delivery (+60k) |
| Solver v3 with a `PreDelivery` entry | the solver must front the WRBTC = inventory again | solver | rejected: does not remove the capital need |
| First-class native sentinel (`address(0)` leg on delta-verify) in Settlement | none | **Settlement** (new address, every maker re-approves, core re-audit) | superseded by the next row: same single-order limits as `NativeBalance` |
| **CoW model:** native sentinel that Settlement PAYS from its own balance in `matchSettle`'s DELIVER step, after the solver unwraps into Settlement in CALL (§6) | none | **Settlement** (`receive()`, sentinel-aware DELIVER; 5 B free today) | **target for the AUDITED rollout**: unlike a measured leg it composes with items and batches |
| **`NativeBalance` view + solver v3 unwrap-and-send** | **none** | solver only | **recommended** |

## 5. What stays from task 28

- `NativeUnwrapModule` (deployed `0xB6107a1D…C735`) stays. It is the right tool for a
  filler that holds WRBTC (inventory, other venues) and for pull orders.
- App and filler shape code for it stays dormant. The app's RBTC entry moves to the
  `NativeBalance` shape once the solver v3 is live.
- **Erratum in its NatSpec** (`NativeUnwrapModule.sol`, the "Posture" note): it cites CoW's
  ETH buy token as an example of a full-gas send. CoW pays with Solidity `transfer`
  (2,300 gas, §6). The rest of the note is correct: a reverting receiver kills the fill
  there too. The source is left unchanged, because the module is deployed and verified,
  and editing even a comment changes the metadata hash and breaks the exact source match.

## 6. Comparison: how CoW Protocol handles native coin

Checked 2026-10-15 against `cowprotocol/contracts` (`GPv2Settlement`, `GPv2Transfer`),
`cowprotocol/services` (driver) and docs.cow.fi.

**Receiving ETH.** The order's buy token is the marker `0xEeee…`.

- `settle()` runs: pre-interactions → pull every sell token → intra-interactions →
  payouts → post-interactions. The inputs are in the contract before the solver's
  interactions run, so the solver unwraps WETH **into the settlement contract** (open
  `receive()`) with no capital of its own. This is our `PostInputs` / netted order.
- The payout is `payable(receiver).transfer(amount)` in `GPv2Transfer.transferToAccounts`:
  a **2,300-gas stipend**. ETH from Balancer internal balances is refused.
- Smart-contract wallets are served **off-chain**. The driver calls `eth_createAccessList`
  on a 1-wei send to each contract receiver and attaches the merged list to the
  settlement tx, so a Safe proxy's cold reads fall outside the stipend. A wallet whose
  `receive()` does real work still cannot be paid.
- A reverting receiver reverts the whole settlement. Solvers simulate and drop the order.

**Selling ETH.** Either wrap first and then trade gaslessly (CoW's recommendation for
repeat users), or use **EthFlow**: an escrow that takes the exact `msg.value` in
`createOrder`, wraps it, owns the order through ERC-1271 and refunds on
`invalidateOrder`, which anyone can call after expiry. EthFlow has these limits:

- sell orders only; in CoW Swap's UI also only market swaps, and no smart-contract wallets;
- the up-front gas is lost if the order fails;
- the auto-refunder only acts at ≥ 2 % slippage.

**Closing a position.** This runs through flash-loan orders plus hooks (Safe, the COWShed
proxy, or Aave's CoW adapters). The order's receiver must be the settlement contract so the
flash loan is repaid. Leftover collateral stays in the user's wallet **as the ERC-20**. No
native option is documented.

| | CoW | Ours |
| --- | --- | --- |
| Native out, plain swap | protocol pushes from its balance | solver pushes, core measures (`NativeBalance`) |
| Who can fill | any solver | the order's `exclusiveFiller` only |
| In a batch | yes | no (`DeltaVerifyNotBatchable`) |
| Together with items / hooks | yes: payout runs after every interaction | no: a delta-verified order carries no items (§7) |
| Withdraw → sell → native | yes (pre-hook withdraw, ETH buy token) | `NativeUnwrapModule` via `matchSettle`, after task 31 |
| Leftover collateral as native | no | no (§7) |
| Gas to the receiver | 2,300 + access lists | all of it (full-gas `call`) |
| Receiver reverts | settlement reverts | fill reverts |
| Selling native | wrap first, or EthFlow escrow | wrap exactly the shortfall before signing |

**What we take from it.**

- **The CoW model is the long-term target** (§4): Settlement holds the unwrapped coin
  for one step and pays it in DELIVER. That is the only design in which native out composes
  with items. It needs a Settlement version, so it belongs to the audited rollout.
- **We do not copy the 2,300 stipend.** It is failure class C10
  ([failure-classes.md](reference-audits/failure-classes.md#c10--hard-coded-gas-stipends-on-value-transfer)).
  CoW needs access lists to get around it, and those cover cold access but not real work.
- **No EthFlow-style escrow for now.** Wrapping before signing is what CoW recommends for
  repeat users. With 7-day limit orders, an escrow would add on-chain cancels or a
  refund keeper.

## 7. Interaction with item flows (closing positions)

Native delivery never mixes with items, and that keeps it safe:

| Path | DIRECT order with items |
| --- | --- |
| `fillWithCallback(PostInputs*)` | refused (`ReverseModeRequiresNoItems`) |
| `matchSettle` / `executeItemFill` | refused (`DeltaVerifyNotBatchable`) |
| forward `fill` | allowed, but the delta check runs in `_deliverOutputs` **before** `_executeItems`; the filler fronts the coin |
| solver / book | `NativeLegShape`, `nativeBalanceMisuse` |

A lending exit therefore cannot inflate a measured native delta. On the only path that
admits items, the check runs first. And every native-aware exit module wraps before it
pays (`FluidCustodyBase._operateOut`, `CompoundV2NativeWithdrawModule`,
`ListaNativeCollateralTakerModule`, rule C10).

The flip side is that **neither native path serves a position close today**:

- **Leftover collateral** after a close (Aave-style WRBTC, Tropykus kRBTC, Fluid native
  vault) is a surplus of TAKE proceeds. The core refunds it to the maker in the wrapped
  token (`Core._payInputsToSolver`, the netted reconcile), **after** the items. No item can
  unwrap it, and `NativeUnwrapModule` only spends an output leg's delivery
  (`requireLegRef`).
- A gasless user may hold no native coin to pay for the unwrap afterwards.
- **Cheapest fix, no core change:** a TAKE item can already name its own recipient. So a
  close can be signed as: repay → TAKE the sold collateral to Settlement → TAKE the
  remainder with `recipient = maker`. The native-aware exit modules then need a
  maker-signed flag: *when the recipient is not Settlement, send raw native with a
  full-gas `call` instead of wrapping.* Fluid must send from the module rather than through
  `operate`'s `to_`, whose send is gas-capped. Venues whose collateral is ERC-20 WRBTC
  would need the same option in the generic withdraw module.
- A full close still needs repay-before-withdraw: one flash around the plan, or a
  counter-order. That is unchanged by task 31.
