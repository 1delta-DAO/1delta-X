# @1delta-x/modules-aave-v3

Aave v3 lending adapters for `Settlement`. Each contract is a
**single-op module** — a thin, stateless adapter that performs exactly one Aave
action (supply, withdraw, borrow, repay) on the order maker's behalf when
Settlement processes an order item. Composed together inside one signed order,
they express leverage, deleverage and cross-protocol migration as a single
atomic intent that any solver can fill.

The dependency points one way: this package depends on `@core`, never the
reverse. The modules live in [`src/`](src/); the fork tests in [`test/`](test/).

## How a module plugs into a fill

A maker signs one `Order` carrying an `Item[]`. Each item names a `module`
and an `op` (`MAKE` or `TAKE`). Settlement walks the items in order, then settles
the `tokenIn → tokenOut` swap leg between maker and solver.

```
            ┌─────────────────────── Settlement.fill ───────────────────────┐
            │                                                                          │
 solver ────┤ 1. solver ──tokenOut──▶ maker            (Permit3 pulls solver's funds)  │
            │ 2. for each Item in order:                                               │
            │      MAKE → module.makeOnBehalf(maker, slice, data)                      │
            │             module pulls the funding token from maker via Permit3        │
            │      TAKE → permit3.take(...) → module.takeOnBehalf(maker, …, receiver)   │
            │             proceeds land at `receiver` (default = Settlement)            │
            │ 3. Settlement ──tokenIn──▶ solver        (local balance + maker shortfall)│
            │ 4. validators / invariants gate the whole fill                           │
            └──────────────────────────────────────────────────────────────────────────┘
```

- **MAKE** = *value in* (deposit / repay): the module pulls the funding token
  from the maker via Permit3 and pushes it into Aave.
- **TAKE** = *value out* (borrow / withdraw): Settlement routes through
  `permit3.take`, which enforces the **taker-allowance gate** on
  `ref = keccak256(data)` before dispatching; proceeds go to `receiver`
  (`address(0)` → Settlement, funding the `tokenIn` payout; `maker` → chains the
  output into a later MAKE item).

`module` and `data` are inside the order's EIP‑712 hash, so the solver cannot
alter which Aave pool/asset is touched or how much.

## Authorization: two gates per leg

A module only moves a maker's funds if **both** of these are signed/approved by
the maker beforehand — Settlement and the solver can never widen them:

| Gate | Who enforces | What it caps |
|---|---|---|
| Permit3 **token** allowance (`approveToken(module, token, cap)`) | Permit3 | how much of *this token* the module may pull from the maker |
| Permit3 **taker** allowance (`approveTaker(settlement, module, ref, cap, expiry)`) | Permit3, TAKE only | how much may be drawn on *this exact position* (`ref = keccak256(data)`). Keyed by **spender = Settlement**, so only Settlement can consume it. |
| Aave **credit delegation** (`approveDelegation(module, cap)`) | Aave | borrow only — Aave's own permission for the module to incur debt |

For a borrow leg all three apply: credit delegation lets Aave mint debt to the
module, while the Permit3 taker allowance is what actually caps the fill size.

> **Security:** the taker book is keyed by spender (Settlement), so a standing
> taker allowance cannot be drained by an arbitrary caller; MAKE modules
> additionally enforce `msg.sender == settlement`. See [`/SECURITY.md`](../../../../SECURITY.md).

## Modules (`src/`)

| Contract | Op | Aave action | `data` |
|---|---|---|---|
| [`AaveV3DepositModule`](src/AaveV3Modules.sol) | MAKE | pull asset from maker → `pool.supply(onBehalfOf = maker)` | `abi.encode(pool, asset)` |
| [`AaveV3RepayModule`](src/AaveV3Modules.sol) | MAKE | pull buffered amount → `pool.repay`; sweep over-repay dust back to maker | `abi.encode(pool, asset, rateMode, debtToken[, DustAction[, permit]])` — debtToken@96 is mandatory (base 128); DustAction@128; permit@160 |
| [`AaveV3PreFundModule`](src/AaveV3PreFundModules.sol) | MAKE (pre-funded) | supply / repay the core-delivered output leg from the module's own balance | `abi.encode(forDesc, pool, asset[, …])` — `forDesc = (5 << 253) \| op << 244 \| token << 16 \| j`: pre-fund leg reference to output leg `j` (bits [0,16)), the funding token at [16,176), the op (`0` Supply, `1` Repay) at [244,252) |
| [`AaveV3WithdrawModule`](src/AaveV3Modules.sol) | TAKE | pull maker's aToken → `pool.withdraw` → `receiver` | `abi.encode(pool, asset, aToken)` |
| [`AaveV3CreditModule`](src/AaveV3CreditModule.sol) | TAKE | `Op.Borrow` — `pool.borrow(onBehalfOf = maker)` → forward to `receiver` | `abi.encode(Op.Borrow, pool, asset, rateMode)` |
| [`AaveV3CreditModule`](src/AaveV3CreditModule.sol) | TAKE | `Op.Leverage` — supply a ratio-derived collateral, then borrow, in one dispatch | `abi.encode(Op.Leverage, pool, borrowAsset, rateMode, collateralAsset, collateralTotal, borrowTotal)` |
| [`AaveV3CreditModule`](src/AaveV3CreditModule.sol) | TAKE_FOR | `Op.Leverage` — same, with the collateral **core-sized** from the funding descriptor | `abi.encode(forDesc, forCap, pool, borrowAsset, rateMode, collateralAsset)` |
| [`interfaces/IAaveV3.sol`](src/interfaces/IAaveV3.sol) | — | minimal Aave v3 pool + credit-delegation surface | — |

Because the modules are pool-address-agnostic, the **same** deposit/borrow
modules drive Aave v3, Spark, or any Aave-v3-fork by passing a different `pool`
in `data` — which is exactly what the migration flow exploits.

The withdraw module takes an optional trailing `BalanceMode` word (at byte 96):
`Full` is the **tagged** word `0xB0DE0001` (`DustHandler.encodeMode(Full)`)
followed by the mandatory `totalAmount`; a bare `1` reverts `InvalidModeWord`.

### Venue-version caveats for forks

- **Pre-v3.5 aToken rounding** (Spark, most Aave-v3 forks, and Aave v3 itself
  before v3.5). An aToken transfer there moves `rayDiv(amount, index)` scaled
  units rounded half-up, and `withdraw` checks `amount <= rayMul(scaled, index)`;
  for ~(1 − RAY/index)/2 of all amounts the round trip is `amount − 1`. The
  `Exact` withdraw therefore measures the aTokens it received and, when short,
  pulls the minimal top-up (a few wei, always on the same aToken allowance) before
  withdrawing exactly `amount`, returning any aToken surplus to the maker. v3.5+
  never takes that branch. A maker who relies on an EXACT-value aToken permit
  tail on a pre-3.5 venue should sign `signedValue` with a few wei of headroom.
- **Isolation mode** (Aave v3.0–v3.6 and forks; removed in v3.7). A first supply
  of a debt-ceiling (isolated) asset is auto-enabled as collateral only when the
  SUPPLIER holds `ISOLATED_COLLATERAL_SUPPLIER_ROLE`. These modules supply on the
  maker's behalf and hold no such role, so a first deposit of an isolated reserve
  through `AaveV3DepositModule`, `AaveV3PreFundModule` or `AaveV3CreditModule`'s
  leverage ops lands as a NON-collateral supply. A module cannot fix this:
  `setUserUseReserveAsCollateral` acts only on `msg.sender` and needs a non-zero
  balance. Consequences: a plain deposit order leaves supply the maker must
  enable themselves (exactly as a direct EOA supply would); a leverage order
  against an isolated reserve reverts at the borrow (no collateral) unless the
  maker already holds an ENABLED balance of that reserve (then `isFirstSupply` is
  false and the flag persists) — or, with other collateral enabled, borrows
  against that other collateral. Order builders should flag reserves with
  `debtCeiling != 0` on pre-3.7 pools for supply-then-borrow shapes. (2026-09-30
  audit, L-AAVE-3: documented, not fixable in a module.)

### One address per grant class

The modules are split by **the standing authorisation a maker has to give them**,
not by seam or by op:

| Grant | Held by |
|---|---|
| Aave **credit delegation** (`approveDelegation` on the debt token) | `AaveV3CreditModule` |
| **aToken** ERC-20 approval | `AaveV3WithdrawModule` |
| Permit3 token allowance (underlying) | `AaveV3DepositModule`, `AaveV3RepayModule` |
| *none* — funded by the fill's own delivery | `AaveV3PreFundModule` |

A credit delegation is standing, protocol-native and in practice granted at
`max`. Every borrow-shaped module used to be a separate permanent liability for
the maker to audit and revoke, and each new one meant another approval prompt
over the same credit line. `AaveV3CreditModule` holds all of them, so a
borrow-shaped op added later costs the maker no new approval. The op rides
inside `data` — and therefore inside `ref = keccak256(data)` — so a taker grant
signed for one op cannot be replayed as another.

The split *between* grant classes is deliberate and bounds the cost of the
merge: a merged contract redeploys as a unit, so folding the aToken-spending or
wallet-allowance ops in here would mean a leverage bugfix forcing every maker to
re-approve their *collateral* too.

A maker who does not want to send an `approveDelegation` transaction can sign
instead: every op accepts an optional EIP-712 `delegationWithSig` block appended
to `data` — `(debtToken, deadline, v, r, s)` (160 bytes), or 192 bytes with an
optional trailing `signedValue`. It is NOT "per-order with nothing left behind"
(audit 2026-09-30 L-AAVE-2):

- the signature commits to a value; without `signedValue` that is this fill's
  slice, so it verifies only on a fill whose slice equals it — in practice a full
  fill. Append `signedValue = item total` to allow partial fills;
- the replay is skipped when a standing delegation already covers the fill;
- the unspent allowance remains, and a CANCELLED order's unconsumed signature can
  still be landed by anyone until its deadline (sign it no later than the order's).

The same optional trailing `signedValue` word applies to every EIP-2612 permit
block (`PermitHelper.replayIfPresent`): a permit block is `(deadline, v, r, s)` =
128 bytes, or 160 with `signedValue`.

> Aave **v4** ships as a separate package,
> [`@1delta-x/modules-aave-v4`](../aave-v4), because v4's Hub/Spoke +
> position-manager architecture is a different integration surface from v3's
> pool. The module *shape* (MAKE/TAKE, Permit3-gated) is identical.

## Flows

### Leverage — deposit collateral, borrow against it

`_buildDepositBorrowOrder`: one MAKE then one TAKE. The maker puts WETH in and
the borrowed USDC funds the `tokenIn` the solver is paid with.

```
order: tokenIn = USDC, tokenOut = WETH      items = [MAKE deposit, TAKE borrow]

  [0] MAKE  AaveV3DepositModule   maker ──WETH──▶ pool.supply(onBehalfOf = maker)
  [1] TAKE  AaveV3CreditModule    pool.borrow(onBehalfOf = maker) ──USDC──▶ Settlement
                                  └─ Aave credit delegation authorises the debt
  settle:   Settlement ──USDC──▶ solver        (entirely from borrow proceeds)
            solver     ──WETH──▶ maker         (tokenOut, the added collateral)
```

### Deleverage — withdraw collateral, swap to repay (`WithdrawAndSwap`)

`_buildWithdrawOrder`: a single TAKE. The maker's aWETH is pulled and burned for
WETH that goes straight to the solver, who pays USDC back as `tokenOut`.

```
order: tokenIn = WETH, tokenOut = USDC      items = [TAKE withdraw]

  [0] TAKE  AaveV3WithdrawModule  maker aWETH ──▶ pool.withdraw ──WETH──▶ Settlement
  settle:   Settlement ──WETH──▶ solver
            solver     ──USDC──▶ maker
```

### Repay — pull buffered debt token, repay, refund the dust (`Repay`)

`_buildRepayOrder`: a single MAKE. The maker signs a *buffered* amount to cover
interest accrual between signing and fill; Aave caps the pull at the live debt
and the module sweeps the remainder back to the maker.

```
order: tokenIn = WETH, tokenOut = USDC      items = [MAKE repay]

  [0] MAKE  AaveV3RepayModule    maker ──USDC(buffered)──▶ pool.repay(min(amt, debt))
                                 └─ residual dust ──USDC──▶ maker   (never to solver)
  settle:   solver ──USDC──▶ maker ;  maker ──WETH──▶ solver
```

### Migration — move a whole position across protocols (`Migrate`)

`_buildMigrationOrder`: four items chained in one atomic fill move a WETH/USDC
position from Aave v3 onto Spark. The withdraw item sets `recipient = maker` to
chain the freed WETH into the next deposit; the final borrow funds the repay.

```
items = [MAKE repay(Aave), TAKE withdraw(Aave)→maker, MAKE deposit(Spark), TAKE borrow(Spark)]

  [0] MAKE  repay     Aave    close USDC debt (buffered)
  [1] TAKE  withdraw  Aave    burn aWETH ──WETH──▶ maker        (recipient = maker, chained)
  [2] MAKE  deposit   Spark   maker ──WETH──▶ Spark.supply
  [3] TAKE  borrow    Spark   Spark.borrow ──USDC──▶ Settlement  (funds the tokenIn payout)

  Net: position leaves Aave and lands on Spark; solver fronts the repay USDC and
       is made whole by the Spark borrow — all-or-nothing.
```

## Security properties

- **Taker modules are Permit3-gated.** `takeOnBehalf` reverts with `OnlyPermit3`
  unless `msg.sender == permit3`. Without it a direct call could bypass the
  taker-allowance gate and drain a delegated borrow/withdraw — see
  [`test/security/TakerModuleAuth.t.sol`](test/security/TakerModuleAuth.t.sol).
- **Repay refunds to the maker, not `data`.** The over-repay sweep destination is
  the `onBehalfOf` function argument, not an attacker-controllable field of
  `data`, closing the "redirect the dust" vector without needing a sender gate.
  A reentrancy lock guards against weird-token transfer hooks.
- **Post-fill invariants.** Orders can carry `IOrderValidator` invariants that run
  after all items execute; a failing one reverts the whole fill and rolls maker
  state back (`test/limit-orders/Invariants.t.sol`).

## Tests

Forked Ethereum mainnet, exercising the real Aave v3 (and Spark) pools.

```
pnpm --filter @1delta-x/modules-aave-v3 test
# or, from the repo root:
forge test --match-path 'packages/modules-aave-v3/**'
```

Coverage spans each flow above plus the limit-order surface (min-fill,
exclusivity, validators, invariants), permit-based fills, and the taker-auth
security check.
