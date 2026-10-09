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
