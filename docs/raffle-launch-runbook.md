# Prize draw + USD₮0 on-ramp — launch runbook

**Day to day, use the operator console. It is a separate Pages project (`packages/raffle-admin`, behind Cloudflare Access), not part of the app.** It needs the
orderbook worker's `RAFFLE_ADMIN_TOKEN`. It has four tabs:

- **Setup & tests**: configure, switch on/off, test mode, run checks, reset a promotion, purge contacts.
- **Feedback**: tallies, every entry, CSV download.
- **Support**: look up an address, add an entry by hand with a note, remove an entry.
- **Draws**: compute qualifiers, dry-run draw, save and fix the draw block, draw, exclude and redraw.

The CLI steps below are the offline equivalent.

The order to switch the public raffle on, run it daily, and close it. The code
is on branch `raffle-onramp-launch`. Main auto-deploys the live beta, so merge it
only when the steps in §1 are done.

## 1. Before merging

| # | Step | Command / where |
|---|---|---|
| 1 | Counsel signs off TC.md: §4.1 (entry = one trade + the signed form), §4.6–4.7 (form and data), and the confirmation wording in `packages/sdk/src/participation.ts` (`PARTICIPATION_STATEMENT`) | — |
| 2 | Re-check the bridge table on-chain (11 routes verified 2026-10-20) | `pnpm --filter @1delta-x/app verify-bridge` |
| 3 | Decide the promotion window and the support link | `PROMOTION.support` in `VITE_PROMOTION` (Telegram group or form URL) |
| 4 | Grant-thread commitments not in the app as of 2026-10-14 (per-user ~1,000 USDRIF cap, total cap, time-bounded allowances): ship them, or say in the thread why not, before promoting on the Collective | `docs/local/rootstock-grant-m1-checklist.md` |

Any later edit to TC.md changes its hash. Update the worker's `RAFFLE_TERMS_HASH`
in the same deploy, or every entry is refused.

## 2. Configure the orderbook worker

```sh
pnpm --filter @1delta-x/app terms-hash        # → 0x… (keccak256 of TC.md)
cd packages/orderbook-worker
wrangler secret put RAFFLE_ADMIN_TOKEN        # a long random string; keep it in the password manager
```

The console's Setup tab can set (and later change) all of this without a deploy.
To bake defaults into the deployment instead, set these in `wrangler.toml` `[vars]`
and run `wrangler deploy`:

```toml
RAFFLE_ID = "rootstock-beta-1"
RAFFLE_TERMS_HASH = "0x…"          # the hash printed above
RAFFLE_STARTS_AT = "<unix seconds>" # fills before this do not unlock Participate
RAFFLE_ENDS_AT = "<unix seconds>"   # entries close here
```

The Durable Object keeps its old env until it restarts. Check before announcing:

```sh
curl https://<app>/api/book/raffle    # {"live":true,"promotion":"rootstock-beta-1","terms":"0x…",…}
```

`terms` must equal the hash the app was built with, or the notice reads "The Terms
were updated" and offers no form.

## 3. Rehearsal in test mode, then the live end-to-end test

On the console, save a config with id `rehearsal-1` and your wallets under
**Testers**. The draw is then live only for those wallets: the public sees no
notice and `/raffle/entrants` and `/raffle/draws` answer 404.

1. Run **Run checks**. Every line should be ✓.
2. Do the steps below from a tester wallet.
3. Run a **Test draw** under Draws.
4. Under Setup, **Reset promotion** `rehearsal-1`.
5. Save the real id with no testers.

Steps from a tester wallet (real funds, small):

Do this from a fresh wallet that holds **no RBTC on Rootstock**:

1. Open the app, then **Bring USD₮0** → Arbitrum → 10 USD₮0 → Bridge. Expect about 0.00045 ETH in fees, and arrival in under 3 minutes.
2. Switch back to Rootstock. Sell 5 USD₮0 for **RBTC** (market order), using the gasless permit path.
   - Expected: native RBTC arrives through solver v3 + NativeBalance, and the wallet never paid gas.
   - This combination (permit-funded order + native RBTC out) has not been filled live before. If it fails, the bridge still works and RBTC delivery is the thing to fix.
3. After the fill is indexed (about 20 s), **Participate** appears. Fill in the form and sign. Expect the "You're in the draw" message.
4. Check that the entry appears under **Feedback** on the console.

## 4. Daily draw (each UTC day, the morning after)

```sh
cd packages/raffle-admin
pnpm raffle-draw snapshot --day 2026-10-25 --book https://<app>/api/book --exclude team.txt --out raffle/
# prints: N qualifying · listHash 0x… · draw block B (~1 h out)
```

1. Review the `⚠ unsized` line, if any, and the CSV.
2. **Publish** the line it prints (day, count, `listHash`, draw block) in the official channel **before block B**. Publish `raffle/<day>.json` with it.
3. After block B + 12, run:
   ```sh
   pnpm raffle-draw draw --snapshot raffle/2026-10-25.json --winners 1
   ```
4. Do the eligibility review of the winner (TC §5, §7.5): look for funding-source clusters among entrants and ask for confirmation if needed. If the winner is excluded, run `draw … --skip <address>`, which deterministically picks the next one.
5. Pay from the treasury wallet, then publish the winner and the payout tx.

`team.txt` lists the addresses of employees, contractors and ambassadors (TC §3.3;
ambassadors run on their own pool). One address per line.

## 5. Close

After the last payout or forfeit:

On the console, use **Purge contacts**, or run:
`curl -X POST -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{}' https://<orderbook-worker>/raffle/admin/purge-contacts`.

This is the deletion TC §4.7 promises. Then pull the feedback for the
freeze-backlog triage:

Use **Download CSV** under Feedback, or call `GET /raffle/admin/entries`.

Use **Switch off** on the console; the app hides the notice as soon as the desk says it is not live.
