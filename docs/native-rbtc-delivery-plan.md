# Native RBTC delivery without capital — plan (2026-10-14)

**Status:** plan. Written after the in-fill unwrap (task 28) turned out to be unfillable by
our zero-capital solver. Supersedes task 28's "inventory or solver v3 with PreDelivery"
options; task 30 tracks the build.

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

The industry does not do it this way. In UniswapX, 1inch (unwrap flag) and CoW (ETH buy
token), the **filler delivers the native coin** as part of its own settlement and the
protocol verifies the receipt. Native delivery is a delivery mode, not a post-fill item.

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
| First-class native sentinel (`address(0)` leg on delta-verify) in Settlement | none | **Settlement** (new address, every maker re-approves, core re-audit) | for the AUDITED rollout; `NativeBalance` gives the same semantics today and stays compatible |
| **`NativeBalance` view + solver v3 unwrap-and-send** | **none** | solver only | **recommended** |

## 5. What stays from task 28

- `NativeUnwrapModule` (deployed `0xB6107a1D…C735`) stays. It is the right tool for a
  filler that holds WRBTC (inventory, other venues) and for pull orders.
- App and filler shape code for it stays dormant. The app's RBTC entry moves to the
  `NativeBalance` shape once the solver v3 is live.
