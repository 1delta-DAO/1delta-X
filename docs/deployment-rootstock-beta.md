# Rootstock (chain 30) pre-audit beta deployment

Deployed 2026-10-09 from commit `b23ec90e5188d8a0f3f04b8e698d3d35398db37b` (clean tree),
deployer `0x00001d4754680958E7f8fe42D60842Ebde4Cb30D`, gas price 23,696,000 wei
(the block `minimumGasPrice`). Pre-audit: these addresses are NOT the audited rollout's.

## Core (CREATE2 via the shared deploy factory, `make deploy-core`, profile `core-deploy`)

- Salt preimage: `pre_audit_deployment_b23ec90e5188d8a0f3f04b8e698d3d35398db37b`
- `CORE_SALT` = keccak256(preimage) = `0x90ed0c47b686da6a02ccb92eef150e9e79c14acf9156e8fd6d2e5c6feed04498`

| contract | address | init-code hash |
| --- | --- | --- |
| Permit3 | `0xabaefb5ae495Dcbce40d1e057346f31A500668a8` | `0x670d5f8442a88fcb0710d2a59c324965a3cc7f90f1f739c1d5520c604d42b6df` |
| Settlement | `0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5` | `0x70c119ce23bedb327e433e969997b77d59eec491b2a90922bb7b69d3b2697dcf` |
| SettlementLens | `0xF9e905EdCC376FDaBF62Ca0966624611721C5206` | `0x65bf396fbe9a0949c9a84bb0e4a39e0e7920823009dce836117fcc9278f35db9` |
| SolverCallbackExecutor (Settlement's CREATE child) | `0x9685D6c5e9934C667680444429B9922D9C598bA0` | — |
| SettlementLensChecks (the lens's CREATE child) | `0x70f88812a449D35F5A42908cB7268A472b9c90B6` | — |

## AggregatorFillSolver (plain CREATE, deployer nonce 3, `make deploy-aggregator-fill`, profile `solvers-deploy`)

| contract | address | constructor |
| --- | --- | --- |
| AggregatorFillSolver | `0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287` | settlement = Settlement, operators = [`0xcafe35944e3195d59b4a354Ea23D60a0445c083a`], policy = (maker 0, protocol 0, recipient 0x0) |
| RouteSandbox (the solver's child) | `0xdadE4B0F9dEa9f2CC371E07f76653971b2c62C04` | (Settlement, Permit3, SolverCallbackExecutor); owner = the solver |

## AggregatorFillSolver v2 (2026-10-12, commit 5388a6f) — LIVE (the filler still drives it; superseded by v3 below once the filler switches)

Direct Uniswap-v3-style pool routes + ERC-2612 permits + gas pass (see packages/solvers
README). Plain CREATE from the same deployer (nonce 4), profile `solvers-deploy` (via-IR,
runs 1,000,000, Cancun), tx `0x3708f6ca34056e4de0ad362a7c269ccad2cab03e55d1864b994e388b780bd8b2`
(block 9,318,298, 5,102,404 gas at 23,696,000 wei = 0.000120907 RBTC).

| contract | address | constructor |
| --- | --- | --- |
| AggregatorFillSolver | `0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1` | settlement = Settlement, operators = [`0xcafe35944e3195d59b4a354Ea23D60a0445c083a`], policy = (0, 0, 0x0), venues = [Oku `0xaF37EC98A00FD63689CF3060BF3B6784E00caD82`, Sushi v3 `0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e`] (init code hash `0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54`) |
| RouteSandbox (child) | `0xda2Db66B3Ae47a1f5F89640666b7802423828c8b` | read from `SANDBOX()` — the script's log printed `0x7891F32f…` (forge's simulated child address, wrong) |

Read back: `SETTLEMENT()` = Settlement, `EXECUTOR()` = `0x9685D6c5…8bA0`, `POOL_VENUES()` = 2,
`poolFor(0, WRBTC, USDT0, 3000)` = `0xaeF6fABf…9Bbd` (the live Oku pool), surplus policy 0/0,
`isOperator(0xcafe…)` = true, `isOperator(deployer)` = false, sandbox `OWNER()` = the solver.

The v1 solver `0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287` (table above) is SUPERSEDED: the
filler no longer drives it; delta-verify orders signed naming it can only be filled by it.

**Retain mode (2026-10-12).** The filler sets `ROUTE_PROFIT_RECIPIENT` = the solver itself,
so its spread stays on `0x48dbdC43…32F1` (no per-fill payout transfer: −5.2k gas direct,
−6.2k pull). Recover it in batches from the operator:
`cast send 0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1 'sweep(address,address,uint256)' <token> <to> <amount>`.
Leave one wei of each token behind — the solver's balance floor keeps the slot warm.
Or run `packages/beta-filler/e2e/sweep-solver.sh`. It signs with a Foundry keystore
(`ACCOUNT`, default `operator`; import the key once with
`cast wallet import operator --interactive`) and asks for the password once. It is a dry
run by default; `--send` broadcasts after you type `yes`. It leaves the 1-wei floors
unless `--all` is given, which is for retiring a solver. `SOLVER` takes a comma list, and
`SWEEP_TO` sets the destination.

## NativeUnwrapModule (2026-10-14, commit 8001ccc) — task 28, RBTC receipts

Plain CREATE from the same deployer (nonce 5), `make deploy-native-unwrap`, profile
`modules-transfer-deploy` (Cancun, runs 20,000), tx
`0xe5f7fc5e4371ca2b9068aa4c75ca404d1c400a7a53985538b6c7133757a31439` (block 9,324,838,
405,258 gas at 26,065,600 wei = 0.0000105633 RBTC). Blockscout: verified.

| contract | address | constructor |
| --- | --- | --- |
| NativeUnwrapModule | `0xB6107a1DEa7Ae04129aBc27ce607249049f3C735` | weth = WRBTC `0x542fDA317318eBF1d3DEAf76E0b632741A7e677d`, settlement = Settlement |

Read back: `WETH()` = WRBTC, `SETTLEMENT()` = Settlement, runtime 1,633 B. Stateless, no
owner.

This is **v1** (source at `8001ccc`): an uncapped send that reverts on failure. The source
in the tree is now v2, with a capped send, a WETH fallback and a 3-argument constructor,
for the task-31 Settlement (native-rbtc-delivery-plan §8). Verify v1 against `8001ccc`.

⚠ **Not fillable by the route solver** (2026-10-14, fork-proven). Its MAKE item needs
outputs delivered before inputs, which `AggregatorFillSolver` (PostInputs; `matchSettle`
refuses pre-funded MAKE) cannot do without capital. It serves fillers that hold WRBTC. The
app's RBTC receipts move to the capital-free `NativeBalance` + solver v3 design:
docs/native-rbtc-delivery-plan.md. Order shape and fork proof: tasks/28 and
`packages/modules/transfer/test/fork/NativeUnwrapRootstock.fork.t.sol`.

## AggregatorFillSolver v3 + NativeBalance (2026-10-15) — task 30, native RBTC delivery

Deployed with `make deploy-native-delivery BROADCAST=1`
(`packages/solvers/script/deploy-native-delivery.sh`). That is ONE `forge script` run of
`DeployAggregatorFill` with `DEPLOY_NATIVE_BALANCE=true`, profile `solvers-deploy` (via-IR,
runs 1e6, Cancun), plain CREATE from the deployer at nonces 6 and 7.

- **Source:** branch `zero-capital-item-fills` on top of `06fac81`, with uncommitted changes
  (solver v3 with `sweepAll` and the hand-encoded `matchSettle` call; task 31's core changes
  are in the tree but do not touch these two contracts).
- **Gas price:** 24,406,880 wei (minimum gas price × 1.03).
- **Cost:** 5,634,314 gas = 0.0001375 RBTC. The deployer is left with 0.0000238 RBTC.

| contract | address | tx | gas |
| --- | --- | --- | --- |
| NativeBalance | `0xA45ec37619C9F9B2f9d54692d578D1b1246c854c` | `0x258791704294374fb6dbccf65135669f9ed55b00f4669a3491bc14e8b20aa4fd` (block 9,326,807) | 106,623 |
| AggregatorFillSolver v3 | `0x5987A4AFE1b680DAC657506B69C56b06FFe86cD1` | `0xa22a7988da96b391c89fa0c7be22491b1ab8d1064c2a1d0ba90804418acab583` (block 9,326,809) | 5,527,691 |
| RouteSandbox (child) | `0xeBbBf5719B699a450b2537852E4286A7e69Bb1aD` | read from `SANDBOX()`. The script's forge log printed `0x31611a70…`, forge's simulated child address, which is wrong, as on v2 | — |

**Constructor:**
- settlement = Settlement;
- operators = [`0xcafe35944e3195d59b4a354Ea23D60a0445c083a`];
- policy = (0, 0, 0x0);
- venues = [Oku `0xaF37…cAD82`, Sushi v3 `0x46B3…202e`], both with init code hash `0xe34f…8b54`;
- nativeBalance = `0xA45e…854c`, wnative = WRBTC `0x542f…677d`.

**Read back 2026-10-15:**
- Code sizes: NativeBalance 246 B, solver 22,777 B, sandbox 2,309 B. The sandbox's `OWNER()` is the solver.
- Solver: `SETTLEMENT()` = Settlement, `EXECUTOR()` = `0x9685…8bA0`, `POOL_VENUES()` = 2, surplus policy 0/0.
- `nativeDelivery()` = (NativeBalance, WRBTC).
- `isOperator(0xcafe…)` = true; `isOperator(deployer)` = false.
- `NativeBalance.balanceOf(deployer)` equals the deployer's RBTC balance; `decimals()` = 18.
- The script's simulation re-derived both live WRBTC/USD₮0 pools through the venues.

**Verified:** Sourcify exact match for both, jobs `00f57d55-70f8-4fe7-bddc-7a451461ab72`
(NativeBalance) and `34443224-7ea3-49e8-8a6e-61ff8706c278` (solver).

**Status: DORMANT until the off-chain switch.** The filler's `AGGREGATOR_SOLVER` still names
v2, and native delivery is off until `NATIVE_BALANCE` (filler, book) and
`VITE_DEPLOYMENTS[30].nativeBalance` (app) are set. Orders signed with v2 as their exclusive
filler can only be filled by v2 until they expire: market orders within 5 minutes, limit
orders up to 7 days. Retained spread on v3 is paid out with
`sweepAll(tokens, to, 1)`; `e2e/sweep-solver.sh` does this.

## Read back on mainnet (2026-10-09)

Settlement `PERMIT3()` = Permit3; lens `SETTLEMENT()` and `CHECKS()` as above; solver
`SETTLEMENT()`, `EXECUTOR()`, `SANDBOX()` as above, `isOperator(0xcafe…083a)` = true,
`isOperator(deployer)` = false, surplus policy 0 / 0 / 0x0; sandbox `OWNER()` = the solver.

## Verification

Blockscout: Permit3, Settlement, SolverCallbackExecutor (forge `--verify`; the solver
step hit Blockscout's API rate limit). Sourcify (Blockscout imports it): solver and
RouteSandbox exact match; SettlementLens and SettlementLensChecks match.

## Cloudflare: Git-linked builds (repo `1delta-DAO/1delta-X`, branch `main`)

Deploy the two Workers first (the Pages project binds to them by name), then Pages.
Checked from a fresh clone (2026-10-09): both `cf:build` + `wrangler deploy --dry-run`
and the app build succeed. pnpm is pinned by the root `packageManager` (10.16.1),
Node by `.node-version` (22).

### Workers Builds — one per worker (Workers → Create → Import a repository)

| setting | orderbook | filler |
| --- | --- | --- |
| Worker name (must equal `name` in wrangler.toml) | `orderbook-1delta-rsk` | `filler-1delta-rsk` |
| Root directory | `packages/orderbook-worker` | `packages/filler-worker` |
| Build command | `pnpm install --frozen-lockfile && pnpm run cf:build` | same |
| Deploy command | `pnpm exec wrangler deploy` | same |
| Build variables | `NODE_VERSION=22` | same |
| Build watch paths | `packages/orderbook-worker/*`, `packages/orderbook/*`, `packages/sdk/*`, `pnpm-lock.yaml` | `packages/filler-worker/*`, `packages/beta-filler/*`, `packages/sdk/*`, `pnpm-lock.yaml` |

`cf:build` builds the worker's workspace dependencies (`@1delta-x/sdk`, and
`@1delta-x/orderbook` for the book): a clone has no `dist/`. Plain vars live in
wrangler.toml and are re-applied on every deploy; set SECRETS in the dashboard
(Settings → Variables and Secrets), they persist across Git deploys:

- orderbook: `BINDING_KEY`, `RPC_URL_SECRET` (keyed Rootstock RPC, required)
- filler: `PRIVATE_KEY` (the key of operator `0xcafe35944e3195d59b4a354Ea23D60a0445c083a`),
  `ADMIN_TOKEN`, `RPC_URL_SECRET`, `QUOTE_BINDING_KEY`, optional `ALERT_WEBHOOK_URL`,
  `ORDERBOOK_BINDING_KEY`

### Pages — the app (Workers & Pages → Pages → Connect to Git)

| setting | value |
| --- | --- |
| Production branch | `main` |
| Framework preset | None |
| Root directory | `/` (repo root) |
| Build command | `pnpm install --frozen-lockfile && pnpm --filter @1delta-x/app build` |
| Build output directory | `packages/app/dist` |
| Build variables | `NODE_VERSION=22`, `PNPM_VERSION=10.16.1`, optional `VITE_GRAPH_KEY` |

The public addresses come from `packages/app/.env.production`; a Pages build
variable of the same name overrides them. `dist/_worker.js` (advanced mode) proxies
`/api/book` and `/api/quote`. After the first build, in Settings → Functions:

- service bindings `ORDERBOOK` → `orderbook-1delta-rsk`, `FILLER` → `filler-1delta-rsk`
- secrets `ORDERBOOK_BINDING_KEY` (= the book's `BINDING_KEY`) and
  `FILLER_BINDING_KEY` (= the filler's `QUOTE_BINDING_KEY`)

then retry the deployment so the bindings take effect.

## Deploy freeze until the audited rollout (2026-10-18)

Everything above is Git-linked to `main`: a push to `main` rebuilds and redeploys the
Pages app and both Workers within minutes, with no further confirmation. The live beta
(the contracts listed on this page) was built from `main`, and the work that follows the
2026-10-18 zero-capital review (`REVIEW-2026-10-18-zero-capital-fills.md`) targets the
**next** Settlement version, so it must not reach `main` before that version is deployed
and `packages/app/.env.production` points at it.

Rules while the freeze holds:

- All review work lands on feature branches (`zero-capital-item-fills` and its
  successors). `main` stays the snapshot the live beta was built from.
- `make hooks` installs `scripts/git-hooks/pre-push`, which refuses any push to `main`.
  A deliberate hotfix to the live beta is `ALLOW_MAIN_PUSH=1 git push origin main`.
- Pushes to other branches are safe: Pages builds them as previews on their own URLs and
  Workers Builds uploads non-production versions; neither touches the production URL.
- Belt and braces, dashboard only (the local wrangler token has no Pages scope):
  Pages → Settings → Builds & deployments → disable "Automatic production branch
  deployments"; Workers → each worker → Settings → Builds → pause. Re-enable both at
  the rollout.
