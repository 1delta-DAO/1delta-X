# Prize draw + USD₮0 on-ramp — launch runbook

**Day to day, use the operator console. It is a separate Pages project (`packages/raffle-admin`, behind Cloudflare Access), not part of the app.** It needs the
orderbook worker's `RAFFLE_ADMIN_TOKEN`. It has four tabs:

- **Qualifiers**: each UTC day's addresses and volumes, who reached the qualifier, copy the list.
- **Feedback**: tallies of the optional feedback, every form, CSV download.
- **Support**: look up an address, delete its feedback on request.
- **Support** also resets the feedback forms after a rehearsal. There is no setup: the draw is fixed copy in the app and is run by hand.

The CLI steps below are the offline equivalent.

The order to switch the public raffle on, run it daily, and close it. The code
is on branch `raffle-onramp-launch`. Main auto-deploys the live beta, so merge it
only when the steps in §1 are done.

## 1. Before merging

| # | Step | Command / where |
|---|---|---|
| 1 | TC.md is the reviewed 2 September 2026 text and must not change. Nothing in the app or the console adds terms of its own: the notice is deliberately vague and the draw is run by hand | — |
| 2 | Decide the promotion window and the support link | `PROMOTION.support` in `VITE_PROMOTION` (Telegram group or form URL) |
| 3 | Grant-thread commitments not in the app as of 2026-10-14 (per-user ~1,000 USDRIF cap, total cap, time-bounded allowances): ship them, or say in the thread why not, before promoting on the Collective | `docs/local/rootstock-grant-m1-checklist.md` |

TC.md must not change (reviewed).

## 2. The orderbook worker

The only raffle-related settings on the worker are `RAFFLE_ID = "rootstock-beta-1"`
in `wrangler.toml` (the key the optional feedback forms are stored under) and the
`RAFFLE_ADMIN_TOKEN` secret for the console:

```sh
cd packages/orderbook-worker
wrangler secret put RAFFLE_ADMIN_TOKEN        # a long random string; keep it in the password manager
```

Nothing on the worker or the console configures the draw. The app states it as fixed
copy (`VITE_PROMOTION` on the app's Pages project: `{"live":false}` hides the notice;
`qualifier`, `pool` and `cadence` are the three strings it shows), and the operator
evaluates each day by hand (§4).

## 3. Rehearsal, then the live end-to-end test

There is nothing to set up for a rehearsal: trade from your own wallet, then check
the console.

1. Do the steps below from your own wallet.
2. Open **Qualifiers** for today (UTC): your wallet should be listed with its volume.
3. Under Support, **Reset** `rootstock-beta-1` afterwards to drop your test feedback.

Steps from your wallet (real funds, small):

Do this from a fresh wallet that holds **no RBTC on Rootstock**:

1. Bridge 10 USD₮0 from Arbitrum to your address on Rootstock through **usdt0.to** (linked from the app). Expect about $1.2 in LayerZero fee and arrival in about 23 minutes. Track it on LayerZero Scan.
2. Open the app on Rootstock. Sell 5 USD₮0 for **RBTC** (market order), using the gasless permit path.
   - Expected: native RBTC arrives through solver v3 + NativeBalance, and the wallet never paid gas.
   - This combination (permit-funded order + native RBTC out) has not been filled live before. If it fails, RBTC delivery is the thing to fix.
3. After the fill is indexed (about 20 s), **Rate the app** appears. Fill in the form and sign. Expect the "Thank you" message.
4. Check that the feedback appears under **Feedback** on the console. (The address was in the day's qualifier list from its first fill, form or no form.)

## 4. The draw, by hand, each morning

The Terms promise no registration (§4.1) and leave the criteria, timing and amounts
to 1delta (§4.2, §4.3, §6.2). So there is no draw machinery: the console lists each
UTC day's qualifying addresses off the fill index and you draw, announce and pay by
hand. The app's notice is deliberately vague ("roughly", "around"), so be generous
with edge cases: someone a little late or early, a day a few cents short.

Announced: around 100 USDRIF, roughly ten daily draws of about 10 USDRIF, a day
counts from roughly $20 of trading.

1. Console → **Qualifiers**: it opens on yesterday (UTC); set "From" and "Days" for a
   range. Each day's table shows every address that traded, its volume valued like the
   Dashboard, and ✓ at or above the qualifier. Look at any `unsized` rows (fills the
   book could not price) before deciding. The exclusion box starts with our own nine
   addresses; add the team's wallets once, the browser remembers them.
2. Fewer than about three qualifiers: skip the day and let the 10 USDRIF ride on the
   next one. Otherwise **Copy qualifying addresses** and pick one at random the way you
   announced (e.g. a published block hash modulo the count, or any method you can show).
3. Review the winner (TC §5, §7.5): funding-source clusters, wallet age, whether its only
   activity is our raffle. If in doubt, pick again.
4. Announce the winning address on the official channels (TC §8.1). Since the form
   collects no contact details, this is how a winner learns. Ask for the §7.5 confirmation
   there if you want one before paying.
5. Pay from the treasury wallet, publish the payout tx. Keep a simple ledger (day, list
   size, winner, tx) in the team drive; the console stores none of it.
6. When about 100 USDRIF has been paid out: hide the notice with `VITE_PROMOTION='{"live":false}'`
   on the app's Pages project and redeploy.

## 5. Close

After the last payout or forfeit, pull the feedback for the freeze-backlog triage.
The form collects no contact details, so there is nothing personal to delete.

Use **Download CSV** under Feedback, or call `GET /raffle/admin/entries`.

Hide the notice with `VITE_PROMOTION='{"live":false}'` on the app's Pages project and redeploy.
