# @1delta-x/raffle-admin — the prize-draw operator console

This is a separate app on its own hostname, deployed as its own Cloudflare Pages
project. It is not part of the trading app, and nothing of it ships in the app's
bundle. The app's `/api/book` proxy cannot reach a `/raffle/admin/*` route.

| Tab | What it does |
|---|---|
| Qualifiers | For a UTC day: every address that traded, its volume valued like the Dashboard, and ✓ at or above the qualifier; copy the qualifying addresses or the day as CSV. Our fillers and the Setup exclusion list are left out. The draw itself is done by hand from this list (the Terms promise no registration and leave criteria, timing and amounts to 1delta). |
| Feedback | Per-question tallies of the optional feedback forms, every form with its answers, CSV download. |
| Support | Look up an address: fills, first fill, feedback. Delete its feedback on request. |
| Setup | The live switch for the app's notice: promotion id, window, daily qualifier, exclusion list. Overrides the deploy's `RAFFLE_*` without a deploy. Reset a promotion's feedback after a rehearsal. |

Every action is a `/raffle/admin/*` call that the orderbook worker authorises with
its `RAFFLE_ADMIN_TOKEN` secret. The console asks for the token and keeps it only
in that browser tab (session storage). It has no secret of its own.

## Code it shares with the app

The `@app` alias (vite.config.ts, tsconfig `paths`) reuses the app's pure libraries
at build time:

- the Dashboard's fill valuation (`lib/dashboard`)
- the pinned tokens (`config/markets`)
- the USD price feed (`lib/usdPrices`)
- the theme hook and the stylesheet

The qualifier list therefore values fills exactly as the Dashboard shows them (`src/qualifiers.ts`).

## Run locally

```sh
# a local orderbook worker with a token
cd packages/orderbook-worker && ./node_modules/.bin/wrangler dev --local --port 8787 --var RAFFLE_ADMIN_TOKEN:dev-admin
# the console (proxies /api/book to :8787; ORDERBOOK_PROXY_TARGET to change)
cd packages/raffle-admin && pnpm dev     # → http://localhost:5176, token "dev-admin"
```

## Deploy: its own Cloudflare Pages project

The project is defined in `wrangler.toml`. It sets the name `raffle-admin-1delta`, the output `./dist`, and the service binding `ORDERBOOK` → `orderbook-1delta-rsk`. While that file exists it is the source of truth for the project's bindings, so don't add them in the dashboard. Deploy the orderbook worker from the same commit first: the console's admin routes only exist from that version on.

### One-time setup

```sh
cd packages/raffle-admin
npx wrangler login                                   # once per machine
npx wrangler pages project create raffle-admin-1delta --production-branch main

# on the ORDERBOOK worker (not this project): the admin token
openssl rand -hex 32                                 # keep it in the password manager
cd ../orderbook-worker && npx wrangler secret put RAFFLE_ADMIN_TOKEN

# optional: the binding key, so per-IP limits bill the operator. Use the SAME value
# as the worker's BINDING_KEY and the app's ORDERBOOK_BINDING_KEY.
echo "$KEY" | npx wrangler pages secret put ORDERBOOK_BINDING_KEY --project-name raffle-admin-1delta
```

### Deploy, option A: direct upload (recommended)

```sh
pnpm --filter @1delta-x/raffle-admin deploy          # build + wrangler pages deploy dist --branch main
```

The console then changes only when someone runs this. A push to main does not touch it.

### Deploy, option B: Git-connected builds

In the dashboard go to Workers & Pages → Create → Pages → Connect to Git, choose this repository, and set:

| Setting | Value |
|---|---|
| Production branch | `main` |
| Root directory | `packages/raffle-admin` |
| Build command | `pnpm build` |
| Build output directory | `dist` |
| Environment variables | `NODE_VERSION=22`, `PNPM_VERSION=10.16.1` |

pnpm finds the workspace from the root directory. `pnpm build` builds the SDK, typechecks and runs `vite build`. Under Settings → Builds → Build watch paths, include `packages/raffle-admin/*`, `packages/app/src/*`, `packages/sdk/*` and `TC.md`, so app-only changes don't redeploy the console. Turn preview deployments off, or protect them too (see below).

### Lock it down: Cloudflare Access (do this before sharing the URL)

1. In Zero Trust, go to Access → Applications → Add → Self-hosted.
2. Domain: `raffle-admin-1delta.pages.dev`. If previews are on, add `*.raffle-admin-1delta.pages.dev` as well.
3. Policy: Allow, with Include set to the team's emails, or the `1delta.io` domain with one-time PIN or SSO.
4. If you give the console a custom domain, add that domain to the same Access application.

Access keeps the page itself private. The admin token is still what authorises every action.

### Check it

Open the console URL, pass Access, sign in with the token, then go to Setup & tests → **Run checks**. Every line should be ✓, except "Inside its window" before the start date.
