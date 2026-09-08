# Lista `LendingBroker` — complete reference (every deployed broker)

Snapshot **2026-09-04**, enumerated live via `Moolah.brokers(id)` over the full
lender-metadata market list (16 Ethereum + 236 BSC Moolah markets), joined with
the **Sourcify-verified** implementation source
(`src/broker/LendingBroker.sol`, solc 0.8.34, chain-1 impl
`0x63fa516949e12f194095562424c6e1d5e2f096f0` — exact match).
**Re-enumerated 2026-09-07** over the union of the live Lista API market list
(paginate with `page=`, NOT `pageNum` — the wrong param silently returns page 1
forever), the metadata list, and a CreateMarket log sweep: BSC unchanged at 20,
Ethereum grew to 4 (two new sUSDS markets, roster §5). Term menus,
dynamic rates and `minLoan` are live reads and WILL drift; everything labeled
"immutable" or "source" is durable.

**24 brokered markets exist: 4 on Ethereum, 20 on BSC** (2026-09-07; 22 at the
2026-09-04 snapshot — brokers get ADDED, so re-enumerate rather than trust any
count in this file). All other Moolah
markets have `brokers(id) == 0` and are plain Morpho-fork markets (borrow/repay
direct on Moolah — the ordinary Morpho module shape, no broker module needed).

---

## 1. One contract, not many — the variants are configuration

There is exactly **one `LendingBroker` source** deployed everywhere:

- Each brokered market gets its **own ERC1967/UUPS proxy** (1 broker : 1
  market; `MARKET_ID()` matches on all 24, set once via `setMarketId`).
- All proxies on a chain share **one implementation**:
  - chain 1: `0x63fa516949e12f194095562424c6e1d5e2f096f0` (Sourcify-verified)
  - chain 56: `0xf1db84c5788fb2174d61e1c98f962f56c224b128` (unverified, but
    **byte-identical runtime** to chain 1's — same 22,462-byte size, identical
    selector set; only the embedded immutables differ)
  - **Upgrades happen in practice**: at block 113.02M (2026-07-30 — the pin
    this package's fork tests run at) the same BSC proxies pointed at
    `0xf71b811970817c67a63eaa503bd956798b33709f`. Every module-relevant
    semantic (the `ZeroAmount()` zero-repay revert, refund-to-caller on
    over-repay, the on-behalf borrow gate) holds on BOTH generations —
    fork-measured on the old impl, source-verified on the new — but a future
    upgrade event re-opens everything this file calls "source".
- Constructor immutables per chain: `MOOLAH` and `WBNB` (the wrapped native —
  **WETH on Ethereum**, despite the name; `address(0)` would disable native
  support, no deployment uses that):

  | chain | Moolah                                       | `WBNB` immutable (wrapped native)            | rateCalculator                               | liquidation whitelist (sole entry)           |
  | ----- | -------------------------------------------- | -------------------------------------------- | -------------------------------------------- | -------------------------------------------- |
  | 1     | `0xf820fB4680712CD7263a0D3D024D5b5aEA82Fd70` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `0xeA00cE2992656A0F1DeDf3bBF082A3c725477796` | `0x0aEfEC58e6339c663E80306e38fFEBbAe0820C70` |
  | 56    | `0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C` | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | `0xF81A3067ACF683B7f2f40a22bCF17c8310be2330` | `0x3AA647a1e902833b61E503DbBFbc58992daa4868` |

- Roles: `DEFAULT_ADMIN_ROLE` (upgrades, must be timelock per source comment),
  `MANAGER` (pauses, liquidation whitelist, `emergencyWithdraw`), `PAUSER`,
  `BOT` (term menu, refinance). Repay/borrow bytecode partly lives in
  `LendingBrokerOperatorLib`, invoked via delegatecall (EIP-170 headroom).

**So "all variants" is not a contract-version matrix.** The axes that change
behavior per market are (§4): wrapped-native loan token or not, collateral
provider shape, oracle wiring, and the (mutable) term menu.

## 2. Mechanics recap

- The broker is the **mandatory debt gateway** of its market: Moolah rejects
  `borrow`/`repay` with `receiver != broker` once a broker is registered.
  Collateral supply/withdraw stays on Moolah (or the market's collateral
  provider) under the USER's address.
- Moolah itself lends at **0% interest** to brokered positions; all interest
  lives in the broker overlay. On repay, interest + penalties are supplied back
  to the market's Moolah **vault** through a per-loan-asset
  `BrokerInterestRelayer` (`RELAYER`).
- Per user: up to `maxFixedLoanPositions` (=100 everywhere) **fixed positions**
  (`FixedLoanPosition {posId, principal, apr, start, end, lastRepaidTime,
  interestRepaid, principalRepaid}` — the `uint256[8]` returned by
  `userFixedPositions`) plus ONE **dynamic position**
  (`{principal, normalizedDebt}`), variable-rate via `rateCalculator`
  (`getRate`/`accrueRate`, bot-fed `ratePerSecond`, manager-capped).
- Rates are stored as `(1 + r) · 1e27` (`RATE_SCALE`). Source bounds on fixed
  terms: `MIN_FIXED_TERM_APR = 1.005e27` (0.5%), `MAX = 1.3e27` (30%).
- `getUserTotalDebt(user)` = authoritative total (fixed + dynamic + interest).
- Early-repay penalty (BrokerMath): repaying fixed **principal** before `end`
  costs `≈ ½ ×` the interest that principal would still accrue to maturity;
  `0` once matured. Interest freezes at `end`; a BOT later
  `refinanceMaturedFixedPositions` moves matured tranches into the dynamic
  bucket (so a user who never flex-borrowed can still hold dynamic debt).

## 3. Entrypoint reference (from verified source)

### Borrow

| signature                                   | caller / auth                                       | payout                                                                                                                                                                             |
| ------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `borrow(uint256 amount)`                    | `msg.sender` only — **flex/dynamic, not delegable** | to `msg.sender`; auto-unwraps to native only if `LOAN_TOKEN == WBNB` **and** `Moolah.providers(id, WBNB) != 0`                                                                     |
| `borrow(uint256 amount, uint256 termId)`    | `msg.sender` only — fixed-term direct               | same unwrap rule                                                                                                                                                                    |
| `borrow(amount, termId, user, receiver)`    | requires `MOOLAH.isAuthorized(user, msg.sender)`    | **always ERC20** to `receiver` (`receiver != 0`); the on-behalf overload the module uses. Debt books to `user`; there is NO on-behalf flex borrow                                   |
| `convertDynamicToFixed(amount, termId)`     | `msg.sender` only                                   | no payout — re-tranches dynamic debt into a fixed position (borrows the accrued interest from Moolah and supplies it to the vault, so Moolah debt grows by the interest)            |

All borrows gate on `whenNotPaused + whenBorrowNotPaused + marketIdSet`, revert
`ZeroAmount` on 0, and validate `minLoan` (below).

### The Moolah authorization gate — a signature-only grant works

The on-behalf borrow (and Moolah-level `withdrawCollateral`) gate on
`Moolah.isAuthorized(user, msg.sender)`. Two grant paths on the DEPLOYED
Moolah:

- on-chain `setAuthorization(operator, true)` from the user, and
- **`setAuthorizationWithSig` — byte-identical to Morpho Blue's**
  (fork-verified by a successful direct relay,
  `test/security/MoolahAuthWithSig.t.sol`): same
  `Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)`
  typehash, same struct + `Signature{v,r,s}` tuple, sequential
  `nonce(address)`, Morpho's chainId+verifyingContract EIP-712 domain scheme,
  relayable by anyone. The ONE rename: the domain view is `domainSeparator()`
  (selector `0xf698da25`); Morpho's `DOMAIN_SEPARATOR()` (`0x3644e515`) is
  absent from the implementation. Morpho-shaped auth tooling
  (`DelegationHelper.replayMorphoAuth`) therefore fits unchanged — only a
  direct view-read needs the renamed selector.

The value-IN ops need no authorization at all: `supplyCollateral` (absent a
provider gate, §4-C) and every broker repay are permissionless on behalf.

### Repay — all three are `payable`, all are **permissionless on-behalf**

| signature                            | targets                                                                              |
| ------------------------------------ | ------------------------------------------------------------------------------------ |
| `repay(amount, onBehalf)`            | the dynamic position                                                                 |
| `repay(amount, posId, onBehalf)`     | one fixed position (`posId` from `userFixedPositions`; global uuid, NOT an index)    |
| `repayAll(onBehalf)`                 | everything — dynamic + every fixed position, full early penalties, repaid **by shares** so no dust remains |

Semantics that the modules must encode around (source-verified):

- **`amount == 0` ALWAYS reverts `ZeroAmount()`.** The ERC20 path
  `transferFrom`s the literal `amount` first and then zero-checks what
  arrived. There is no "0 = repay my balance" convention on the broker.
- **Native**: if `msg.value > 0`, it OVERRIDES `amount` entirely and requires
  `LOAN_TOKEN == WBNB` (else `NativeNotSupported`). Works on every
  wrapped-native-loan market regardless of provider registration.
- **Interest first, then penalty, then principal.** Excess beyond the debt is
  **refunded to `msg.sender`** (the payer, NOT `onBehalf`) — so an
  over-funded repay from a module refunds to the module, sweepable to the
  maker. Over-repay is therefore safe and the right way to close.
- `repayAll` pulls **exactly `totalDebt`** (computed live at execution) via
  `transferFrom` — so the ERC20 allowance and balance must cover accrual
  between quote and execution; approve a ceiling. Native: send
  `msg.value >= totalDebt`, excess refunds as native.
- **`minLoan` floor on the REMAINDER**: a partial repay (or borrow) leaving
  `0 < remaining < Moolah.minLoan(marketParams)` reverts
  `"broker/fixed-below-min-loan"` / `"broker/dynamic-below-min-loan"`. Live
  values ≈ $15–$26 in loan-token units (see roster). Full closes never hit it.
- A repay targeting a matured `posId` **races the refinance bot**: after
  `refinanceMaturedFixedPositions` the posId is gone (`PositionNotFound`) and
  the debt sits in the dynamic bucket — fall back to the dynamic overload, or
  use `repayAll` which is immune to the race.
- `paused()` blocks **repay too** (all three), not just borrows;
  `borrowPaused` blocks only borrows + `convertDynamicToFixed`. Currently all
  24 brokers: `paused = false`, `borrowPaused = false`.

### Liquidation (context only — not a module surface)

On a brokered market Moolah-level liquidation runs THROUGH the broker:
`broker.liquidate(...)` (wraps `Moolah.liquidate`, cascades the seizure across
dynamic-then-earliest-maturity fixed positions) is gated by the broker's
liquidation whitelist — empty would mean permissionless, but **every deployed
broker whitelists exactly one address** (Lista's `BrokerLiquidator`, one per
chain, table §1). Bad debt settles via the broker-only
`Moolah.liquidateBrokerPosition`. So liquidations on brokered markets are
fully permissioned today.

### Views

`getFixedTerms() → (termId, duration, apr)[]` (the borrow menu),
`userFixedPositions(user)`, `userDynamicPosition(user)`,
`getUserTotalDebt(user)`,
`previewRepayFixedLoanPosition(user, amount, posId) → (interest, penalty,
principal)` (size exact closes with it), `peek(token, user)` (the
user-deflated oracle price, §4-D), `getLiquidationWhitelist()`,
`borrowPaused()`, `paused()`.

## 4. Variant axes — what the module must parameterize

**A. Chain.** Immutables (`MOOLAH`, wrapped native), rate calculator, relayer
set, liquidator — all per chain. Same bytecode.

**B. Loan token: plain ERC20 vs wrapped native.** 4 of 24 markets lend the
chain's wrapped native (2× WETH on Ethereum, 2× WBNB on BSC). On those:
native **repay** via `msg.value` always works; native payout on **direct**
borrows additionally needs a loan-side native provider registered
(`Moolah.providers(id, WBNB) != 0`) — today true ONLY for BSC slisBNB/WBNB;
the two Ethereum WETH markets and the SmartLP/WBNB market pay ERC20 even on
direct borrows. The on-behalf borrow the module uses pays ERC20 always —
chain an unwrap step if native delivery is wanted.

**C. Collateral provider shape** (orthogonal to the broker — it gates the
COLLATERAL legs; the broker gates the DEBT legs). Four shapes among the 24:

- **none** (16 markets, both new sUSDS rows included): plain Moolah
  `supplyCollateral`/`withdrawCollateral`.
- **erc20** — the slisBNB provider `0x33f7A980…` (5 BSC markets): forwards
  Moolah's own selectors token-for-token; the Morpho-shaped modules work
  pointed at it (fork-verified — supply, exact/full withdraw, sig-auth).
- **native** — `0x367384C5…` (WBNB/lisUSD): **NOT a forwarder** (corrected
  2026-09-07 — an earlier revision of this file called it "Moolah selectors +
  native wrap variants"): `supplyCollateral` is a 3-arg PAYABLE whose amount
  is `msg.value` (the Morpho-shaped 4-arg ERC20 supply REVERTS, fork-pinned),
  and `withdrawCollateral` keeps Morpho's 4-arg selector but UNWRAPS and pays
  `receiver` raw native. ERC20-only modules cannot touch this market's
  collateral; it takes the dedicated wrap/unwrap pair (`ListaNativeModules`,
  the cEther pattern — maker/solver see WBNB ERC20 only).
- **smart-lp** — `SmartProvider 0xC3be83DE…` (slisBNB & BNB-SmartLP/WBNB, the
  ONE brokered SmartLP market): a DIFFERENT ABI (two-coin StableSwap zap;
  the collateral receipt is `onlyMoolah`-transferable, so deposits take a
  POOL COIN and withdrawals pay one out). The Morpho-shaped modules cannot
  serve it; `ListaSmartModules` runs the one-sided shapes
  (`supplyCollateral` with the other coin 0, `withdrawCollateralOneCoin`).
  Resolve the shape from `lista-collateral-providers.json` and FAIL CLOSED
  on unknown providers.

**D. Oracle wiring — the one real generation split.** On 21/24 markets the
Moolah market's `oracle` IS the broker: its `peek(token, user)` deflates the
user's collateral price by their unbooked broker interest, so Moolah's health
check (withdraw + liquidation) sees broker debt despite Moolah's 0% rate. On
the **3 legacy lisUSD markets** (slisBNB/lisUSD, WBNB/lisUSD, BTCB/lisUSD —
the earliest brokers) the market oracle is the plain MultiOracle
`0xf3afD82A…`, NOT the broker: Moolah-level health there does not reflect
broker interest the same way. Detect with
`idToMarketParams(id).oracle == broker`, don't hardcode the trio.

**E. Term menu — per broker, BOT-mutable, including REMOVAL.**
`updateFixedTermAndRate(term, removeTerm)` can add, reprice, or delete a
termId at any time. **termIds are not stable and not positional**: the same
three lisUSD brokers serve `termId 4 (30d), 2 (7d), 3 (14d)` — termId 1 was
removed and replaced by 4 — while the other 19 serve `1/2/3 = 7/14/30d`.
Always read `getFixedTerms()` live before encoding a fixed borrow; a stale
termId reverts `TermNotFound`. APR is bounded 0.5%–30% by the contract (many
menus currently sit AT the 0.5% floor).

**F. Debt bucket on repay.** Fixed (`posId`) vs dynamic (no posId). The SDK's
`type(uint128).max` sentinel is a calldata convention that must be mapped to
the two-arg overload — the broker itself takes a plain `uint256 posId` and
would revert `PositionNotFound` on the sentinel. Dynamic debt can exist even
for pure fixed-term borrowers (bot refinance, §2), so a full-close flow must
handle both buckets — or just use `repayAll`.

**G. Interest relayer (informational).** `RELAYER` is shared per LOAN ASSET,
not per market (lisUSD `0xcb2590…`, USDT `0x2A119f…`, USD1 `0x35720f…`, U
`0x934892…`, WBNB `0xF2D18e…` on BSC; `0xeBf4A1…` on Ethereum) — the vault
each asset's interest revenue flows into. No module involvement.

## 5. Roster — all 24 brokered markets

Columns `terms` / `dyn` (dynamic APR) / `minLoan` are live snapshots
(2026-09-04); `provider` names the collateral-provider shape (§4-C);
`nat-loan` = loan token is the wrapped native; `orc=brk` = broker is the
market oracle (§4-D).

### Ethereum (chain 1) — 4 brokers

The two sUSDS rows were REGISTERED BETWEEN THE SNAPSHOTS (their live columns
read 2026-09-07); they are also the first brokered markets whose loan token is
NOT 18-decimal — Ethereum USDT/USDC are 6-dec, so `minLoan` ≈ `15e6` units.

| market (Moolah id)                                                   | pair        | LLTV  | broker                                       | provider | nat-loan | orc=brk | terms (termId: days @ APR)                  | dyn    | minLoan       |
| -------------------------------------------------------------------- | ----------- | ----- | -------------------------------------------- | -------- | -------- | ------- | ------------------------------------------- | ------ | ------------- |
| `0x3c5df5e6d9bb476222ae75241bc5b829f0f03b7f7df3d8130dcb737b31f7c63c` | wstETH/WETH | 96.5% | `0x39acab377A7cA24c1BF4B2AE5294F57519d8719B` | —        | ✓ (WETH) | ✓       | 1: 7d @5.11%, 2: 14d @4.89%, 3: 30d @2%     | 0.16%  | ~0.0061 WETH  |
| `0x7f0bca353cd2ff89d16f15a9fd8018ce5f268897923ce0c6fbf1bc8e3f27ac18` | wBETH/WETH  | 96.5% | `0x2B7cb7Fe6C545e23cb96f2B8E7e5120fF9e16444` | —        | ✓ (WETH) | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.04%  | ~0.0061 WETH  |
| `0x4c7ad7bc7cc8383ba6243de0b872e8b94ec12f9a79619a791ef1a9490899b299` | sUSDS/USDT  | 94.5% | `0x1961ef66C252cDCB09FaF464Ea1360Ca4bb4269C` | —        |          | ✓       | 1: 7d @3.22%, 2: 14d @3.08%, 3: 30d @2%     | 0.04%  | ~15.0 USDT (6-dec) |
| `0xba7fa442a212c9fda3c853f951c4fc9c6bcc8b8f377e7ca0cd7d99372fa59111` | sUSDS/USDC  | 94.5% | `0x0780b0E16C6d60798AFee808633f1E91665b403a` | —        |          | ✓       | 1: 7d @0.66%, 2: 14d @0.63%, 3: 30d @0.57%  | 0.08%  | ~15.0 USDC (6-dec) |

### BSC (chain 56) — 20 brokers

| market (Moolah id)                                                   | pair                | LLTV  | broker                                       | provider  | nat-loan | orc=brk | terms                                       | dyn    | minLoan      |
| -------------------------------------------------------------------- | ------------------- | ----- | -------------------------------------------- | --------- | -------- | ------- | ------------------------------------------- | ------ | ------------ |
| `0x078d06a2c852f94c05f291b7288e5120d104ef0e9aa27632df4cb0b6f03cefdc` | slisBNB/lisUSD      | 86.0% | `0x0cffd57f93190892ac2dB8A01596304268Bc2014` | erc20     |          | ✗       | **4**: 30d @3.23%, 2: 7d @3.83%, 3: 14d @3.43% | 3.06%  | 15 lisUSD    |
| `0x1fed91636b77dab38fd796e21580718aa51e8cf89e442a0268de786adc544596` | PT-sUSDE-9APR26/U   | 94.5% | `0xFA25B61ac2c31E82DDE626EE2704700646a2C6E3` | —         |          | ✓       | 1: 7d @3.23%, 2: 14d @3.09%, 3: 30d @2.81%  | 1.57%  | ~15 U        |
| `0x212d0a36fccb86ff79994d6094271c21149c6a65e97e5ed797429ee56f44ce64` | sUSDe/USD1          | 91.5% | `0xCA5929B8fF8B1a4B9B8d77DFc5340977BFa425B3` | —         |          | ✓       | 1: 7d @5.78%, 2: 14d @5.53%, 3: 30d @5.04%  | 2.43%  | ~15 USD1     |
| `0x226935103b730aefad53849e4cf7d92f30083cc417222f395478dabdd9ff3cac` | slisBNB/WBNB        | 96.5% | `0x1Fa26015286D1270343d7526C60bd57aB6bE8b54` | erc20     | ✓ + unwrap | ✓     | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.39%  | ~0.021 WBNB  |
| `0x2a679d85b2c64c6e72dc6d98c63f4ddbdae44dda0be4f93a87391192023f733b` | WBNB/lisUSD         | 86.0% | `0x6BAF9648cffB7C9c4cB7275000a27b9a7dBD59Bc` | native    |          | ✗       | **4**: 30d @3.23%, 2: 7d @3.83%, 3: 14d @3.43% | 3.06%  | 15 lisUSD    |
| `0x34b10e29626e1829e24e44bffd0b6795eb901120d9fcb6217973a67589b3b8e4` | slisBNB&BNB-SmartLP/WBNB | 96.5% | `0x3ade951523e81dD45e5787bb0b95Ce7341Db1287` | smart-lp | ✓  | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.12%  | ~0.021 WBNB  |
| `0x3aeffa0dbe7aa8e3f3ae23c56f3aaf183af5f3736745a627e741cffb4ebfd6f3` | USDe/USD1           | 91.5% | `0xFDFc9A306084BCa33885b76d23C885dB9E3a6e72` | —         |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 2.29%  | ~15 USD1     |
| `0x4fe11b7007a4e09f1f274bfd152b636d7d64b4637df6b645c1516b05590797db` | USDe/USDT           | 91.5% | `0x07b72Adbe196E2E83242C3414eee5Fd7E4c0cD74` | —         |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.49%  | ~15 USDT     |
| `0x6ef28e9f52ffd5e66b14ba95f3da17b782ce8c4a592218fa32f917ca10f4f054` | BTCB/U              | 86.0% | `0xFEb7D3Deb6a4CEE8f5da4F618098Ac943440Ff69` | —         |          | ✓       | 1: 7d @2.14%, 2: 14d @2.05%, 3: 30d @1.87%  | 1.15%  | ~15 U        |
| `0x76d7eaeb9d087629c477c51b13914f2489506ec25e7f494aedecee757ad539c8` | slisBNB/USDT        | 86.0% | `0xf9502555CC9A4D3ea557BB79b825CA10B3A8344F` | erc20     |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 1.17%  | ~15 USDT     |
| `0x864a59352d12006ab1b194176c30b0e3f538e98baf78e9ee1c0d36e852727f77` | USDe/U              | 91.5% | `0x52ee1F685ef41E8D1158E2508dC46561Ca839864` | —         |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.49%  | ~15 U        |
| `0x86e6bfa9e590d003ce03e34a79a4986120c4ced545ab62db484e43acb049c6a1` | sUSDe/USDT          | 91.5% | `0x306b7122adb734bD3976f6Fb7dC5E8fEf57528D7` | —         |          | ✓       | 1: 7d @5.78%, 2: 14d @5.53%, 3: 30d @2.5%   | 2.71%  | ~15 USDT     |
| `0x8de2e1f3e3935024a2667d8203983bdff70a1aee0c91665760e02c257d53032f` | BTCB/USD1           | 86.0% | `0x41E2a8C0f0e60ec228735a9ACDe704ff73df7981` | —         |          | ✓       | 1: 7d @4.23%, 2: 14d @4.05%, 3: 30d @2%     | 0.46%  | ~15 USD1     |
| `0x95f93825819b67a64610e6adb9ac5f70d5108f5121b9df6551e23a4a7a801b5b` | slisBNB/USD1        | 86.0% | `0xF07b74724cC734079D9D1aa22fF7591B5A32D9d2` | erc20     |          | ✓       | 1: 7d @10.07%, 2: 14d @9.65%, 3: 30d @2%    | 2.88%  | ~15 USD1     |
| `0xaaf06d7c7fd32ac1b478bdf6f068d707ea32982f299b684ef79b1023a51ad3db` | slisBNB/U           | 86.0% | `0xDf05774Cd68cE1FBaE01be3181524c904f91d628` | erc20     |          | ✓       | 1: 7d @2.13%, 2: 14d @2.04%, 3: 30d @1.85%  | 1.12%  | ~15 U        |
| `0xab3827ad876b82fb5af9af8bf3f0bbc8a01e8602389053a71513db72c5f129f7` | BTCB/lisUSD         | 86.0% | `0x30DDB3A48863E4897AaCDD5D202E23270d75BaE1` | —         |          | ✗       | **4**: 30d @3.23%, 2: 7d @3.83%, 3: 14d @3.43% | 3.06%  | 15 lisUSD    |
| `0xc1264ae84203b5660478bba5cfe15d9f579aa98402fb073bff65c31040f12f1a` | PT-sUSDE-9APR26/USD1 | 94.5% | `0xf7c4701e90867f33745F73d5edF2143f0DE03f9d` | —        |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.45%  | ~15 USD1     |
| `0xca1432913a86b41eb10c66de79fe390b877c811a113755e9efb10f38de862450` | PT-sUSDE-9APR26/USDT | 94.5% | `0xa26488154D61f8977153915510564ce47a5072dD` | —        |          | ✓       | 1: 7d @0.5%, 2: 14d @0.5%, 3: 30d @0.5%     | 0.33%  | ~15 USDT     |
| `0xd6fe8c8658b8cc7e0f413b0e45e94646cc2ee9255e9500b0db0ee8c2c1499bff` | sUSDe/U             | 91.5% | `0x3350fC3c54CE501083a60707823833e67168bb94` | —         |          | ✓       | 1: 7d @5.78%, 2: 14d @5.53%, 3: 30d @5.04%  | 2.38%  | ~15 U        |
| `0xea00a233473bc0585326eec959623a054798b7543205c5079bab49015a2bf810` | BTCB/USDT           | 86.0% | `0xa94d926937f29553913A50feDC365De69162613d` | —         |          | ✓       | 1: 7d @3.23%, 2: 14d @3.09%, 3: 30d @2%     | 2.23%  | ~15 USDT     |

Provider addresses (BSC): erc20/slisBNB `0x33f7A980a246f9B8FEA2254E3065576E127D4D5f`,
native `0x367384C54756a25340c63057D87eA22d47Fd5701`, smart-lp
`0xC3be83DE4b19aFC4F6021Ea5011B75a3542024dE`. "U" is the U stablecoin, 18 dec;
22 of 24 loan tokens are 18-decimal (BSC USDT/USDC are 18-dec) — the
EXCEPTIONS are the two new Ethereum sUSDS markets, whose USDT/USDC are 6-dec:
never assume 18 decimals from this roster.

**The roster is data, not code.** New brokers appear whenever Lista registers
one (`Moolah.setMarketBroker`); resolve `Moolah.brokers(id)` (immutable per
market once set — cache forever) instead of hardcoding this table.

## 6. Consequences for the modules in this package

1. **The on-behalf borrow is CONFIRMED from verified source** — the README's
   "confirm against the deployed `LendingBroker`" caveat is resolved:
   `borrow(amount, termId, user, receiver)` exists on every deployed broker,
   gates on `MOOLAH.isAuthorized(user, msg.sender)` (the Moolah
   `setAuthorization` grant), requires `receiver != 0`, and always pays ERC20.
   That grant is now **signature-only capable**: `ListaTakerModule` accepts an
   optional maker-signed auth tail (op 0: `moolah@96`, 160-byte
   `replayMorphoAuth` block @128; op 1: block @256 in `Exact`, @288 in `Full`
   — BalanceMode must then be encoded explicitly) and replays
   `setAuthorizationWithSig` in-call, so the maker needs no prior on-chain
   Moolah transaction (§3; fork-proven end-to-end by
   `test/security/MoolahAuthWithSig.t.sol`).
2. **`repay(0, …)` reverting `ZeroAmount()` is a SOURCE fact, not a fork
   quirk** — `_pullPayment` transfers the literal amount, then zero-checks.
   `ListaBrokerRepayModule` (the MAKE module in `ListaModules.sol`)
   originally encoded `repay(0, …)` and could not execute against any
   deployed broker; **fixed 2026-09-04** with the pre-fund-module correction —
   it passes the explicit maker-signed ceiling and relies on
   repay-up-to-debt + refund-to-caller (the refund lands on the module =
   `msg.sender`, swept to the maker). Fork-proven by
   `test/leverage/BrokerRepay.t.sol`: a flex and a fixed position each
   closed with an overshoot ceiling against the deployed BSC broker — at the
   fork pin, i.e. the pre-upgrade impl `0xf71b…709f` (§1); the current impl's
   verified source shows the same semantics — plus a pin that `repay(0, …)`
   reverts `ZeroAmount()` on both overloads.
3. **`repayAll(onBehalf)` is the clean full-close — now a module op**
   (2026-09-05): `loanId == type(uint256).max` on `ListaBrokerRepayModule`
   maps to it (in `ILista.sol`; selector `0x7c27383b`, verified present on
   both impl generations, §1). One call retires dynamic + all fixed positions
   by SHARES (no dust), immune to the refinance race, and refunds nothing —
   it pulls exactly the live `totalDebt`, capped by the module's scoped
   approval at the maker-signed ceiling, so a ceiling short of the live debt
   fails closed in the broker's `transferFrom` and the un-pulled remainder
   sweeps to the maker. Fork-proven (both buckets closed in one item, plus
   the short-ceiling revert pin) in `test/leverage/BrokerRepay.t.sol`.
4. **Partial repays must respect the `minLoan` floor on the remainder** —
   sizing a repay that leaves a sub-$15 stub reverts. Clamp partials away
   from the floor or promote them to full closes.
5. **Read `getFixedTerms()` live per broker before encoding a borrow** —
   termIds are bot-mutable and already diverge (the lisUSD trio's `4/2/3`).
6. **The loanId sentinels are our convention, not the broker's**:
   `type(uint128).max` maps to the 2-arg `repay(amount, onBehalf)` (dynamic)
   and `type(uint256).max` to `repayAll(onBehalf)` (full close, item 3);
   never forward either as a posId — the broker takes a plain `uint256` and
   would revert `PositionNotFound`. Fixed posIds are small sequential uuids,
   so neither sentinel can collide.
7. **Only the debt side is brokered — and every collateral shape is now
   served** (2026-09-07). Collateral legs follow the market's provider shape
   (§4-C): none → the Morpho-shaped modules on Moolah; erc20 → the same
   modules pointed at the provider (withdraws via `ListaTakerModule` op 2,
   which splits venue/auth so the sig-only Moolah grant still works); native
   → the `ListaNativeModules` wrap/unwrap pair; smart-lp →
   `ListaSmartModules` (one coin in/out, rate-scaled slippage floors — LP
   units on the burn side, since the receipt itself is untouchable). The one
   brokered SmartLP market (broker debt + SmartProvider collateral in the
   same position) is fork-proven end to end in
   `test/leverage/SmartLp.t.sol`.
8. **Flex borrow and `convertDynamicToFixed` are `msg.sender`-only** — EOA
   direct, permanently outside module reach (correctly omitted).
9. **The push (TAKE_FOR) siblings need NOTHING on the receive side.**
   `ListaPreFundModules.sol` adds `ListaPreFundSupplyCollateralModule` and
   `ListaPreFundBrokerRepayModule`: the maker signs the converted output leg
   with `recipient = module`, the core sizes `forAmount` to exactly that
   delivery, and the module supplies/repays it from its own balance —
   possible precisely because both value-in venue ops are permissionless on
   behalf (§3): no ERC20 approval, no Permit3 token allowance, and no Moolah
   authorization on the received asset. The pre-fund repay passes the literal
   `forAmount` and leans on the refund-to-`msg.sender` semantic (§3) to
   sweep exactly `forAmount − consumed` back to the maker. The provider gate
   (§4-C) still excludes provider-gated markets from the push
   supply-collateral leg — check `providers[id][collateralToken] == 0`
   off-chain. Leg-reference descriptors only (literal/balance forms are
   rejected); fork-proven by `test/leverage/PreFundOneSided.t.sol`. The push
   repay deliberately keeps the literal-amount overloads and NOT `repayAll`:
   `forAmount` is delivery-sized, and a delivery a wei short of the live debt
   would revert the whole fill on `repayAll`'s exact pull, where the literal
   repay degrades gracefully to a partial close.

## 7. Related in-repo references (lending-sdks workspace)

- `packages/margin-fetcher/README.md` → "Fixed-term broker (`LendingBroker`)"
  — data-model mapping (`terms[]`, `debtStable`, late-repay table).
- `packages/margin-fetcher/src/lending/public-data/lista/listaBroker.ts` —
  broker resolution + term/user multicalls (the read patterns above).
- `packages/calldata-sdk/src/evm/generic/lista/README.md` — native provider
  decision matrix + SmartLP ABI split.
- `packages/calldata-sdk/src/evm/generic/lista/listaBrokerLending.ts` —
  composer-op encodings (`LISTA_BROKER_BORROW`/`_REPAY`, sentinel).
- lender-metadata: `config/morpho-type-markets.json` (`LISTA_DAO` market
  list), `data/lista-collateral-providers.json`, `data/lista-providers.json`.
