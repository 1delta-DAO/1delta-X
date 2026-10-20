# @1delta-x/raffle-admin — the prize-draw operator console

This is a separate app on its own hostname, deployed as its own Cloudflare Pages
project. It is not part of the trading app, and nothing of it ships in the app's
bundle. The app's `/api/book` proxy cannot reach a `/raffle/admin/*` route.

| Tab | What it does |
|---|---|
| Setup & tests | Edit the draw's config: promotion id, Terms hash, window, qualifier, exclusions. This overrides the orderbook's `RAFFLE_*` without a deploy. Also: switch the draw off, revert to the deploy defaults, and **test mode**. In test mode the draw is live only for the tester wallets you list; the public sees nothing. Run checks, **reset** a promotion (deletes its entries and draws), purge contacts. |
| Feedback | Per-question tallies, every entry with its answers, CSV download. |
| Support | Look up an address (fills, first fill, entry). Add an entry by hand with a required note, e.g. "I signed up but I'm not listed". Remove an entry. |
| Draws | For a UTC day: compute the qualifiers, run a dry-run draw, save the list and fix a future draw block, then draw from that block's hash. Exclude a winner and redraw. Records are public at `GET /raffle/draws`. |

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

A draw therefore values fills exactly as the Dashboard shows them. The draw rules
are in `src/draw.ts`, shared by the console and the CLI.

## Run locally

```sh
# a local orderbook worker with a token
cd packages/orderbook-worker && ./node_modules/.bin/wrangler dev --local --port 8787 --var RAFFLE_ADMIN_TOKEN:dev-admin
# the console (proxies /api/book to :8787; ORDERBOOK_PROXY_TARGET to change)
cd packages/raffle-admin && pnpm dev     # → http://localhost:5176, token "dev-admin"
```

## Deploy (Cloudflare Pages, a NEW project, e.g. `raffle-admin-1delta`)

1. Build command `pnpm --filter @1delta-x/raffle-admin build`. Output directory `packages/raffle-admin/dist`. `public/_worker.js` travels with the output.
2. Bindings:
   - a service binding `ORDERBOOK` to the orderbook worker, or else an `ORDERBOOK_ORIGIN` variable;
   - optionally `ORDERBOOK_BINDING_KEY`, the same value as the app's, so per-IP limits bill the operator.
3. Put **Cloudflare Access** in front of the project (restrict it to the team's emails). The token authorises actions; Access keeps the console out of sight.
4. On the orderbook worker, set the secret: `wrangler secret put RAFFLE_ADMIN_TOKEN`.

## CLI

`pnpm --filter @1delta-x/raffle-admin raffle-draw snapshot|draw …` is the offline
equivalent of the Draws tab, using the same rules from `src/draw.ts`. Its help text
is at the top of `scripts/raffle-draw.ts`.
