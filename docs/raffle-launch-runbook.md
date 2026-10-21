# Prize draw + USD₮0 on-ramp — launch runbook

**Day to day, use the operator console. It is a separate Pages project (`packages/raffle-admin`, behind Cloudflare Access), not part of the app.** It needs the
orderbook worker's `RAFFLE_ADMIN_TOKEN`. It has four tabs:

- **Qualifiers**: each UTC day's addresses and volumes, who reached the qualifier, copy the list.
- **Feedback**: tallies of the optional feedback, every form, CSV download.
- **Support**: look up an address, delete its feedback on request.
- **Setup**: the live switch, the window, the qualifier, the exclusion list, reset.

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

### The live configuration (rootstock-beta-1)

The deploy sets `RAFFLE_ID = "rootstock-beta-1"` in `wrangler.toml`, so the desk is
live as soon as the worker is deployed; the console's Setup tab adjusts the rest
without a deploy.

| Setting | Value |
|---|---|
| Promotion id | `rootstock-beta-1` |
| Starts | the announcement day, 00:00 UTC (fills before it do not unlock the feedback form) |
| Notice goes dark | leave empty; switch off by hand when the pot is paid out |
| Daily qualifier | $20 (what the Qualifiers tab marks ✓; the notice says "roughly") |
| Excluded from the qualifier list | the addresses below plus every team member's personal wallet |

Addresses to exclude (our fillers `0xcafe…083a`, `0x5987…6cD1`, `0x48db…32F1` are excluded automatically; list them anyway), pasteable:

```
0x00001d4754680958E7f8fe42D60842Ebde4Cb30D
0xcafe35944e3195d59b4a354Ea23D60a0445c083a
0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287
0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1
0x5987A4AFE1b680DAC657506B69C56b06FFe86cD1
0xdadE4B0F9dEa9f2CC371E07f76653971b2c62C04
0xda2Db66B3Ae47a1f5F89640666b7802423828c8b
0xeBbBf5719B699a450b2537852E4286A7e69Bb1aD
0xB6107a1DEa7Ae04129aBc27ce607249049f3C735
```

(deployer, filler operator, solver v1/v2/v3, sandboxes v1/v2/v3, NativeUnwrapModule)

## 3. Rehearsal, then the live end-to-end test

On the console, save a throwaway id such as `rehearsal-1` with the qualifier set to
$1. The rehearsal is public while it runs, so anyone could enter it, but a reset
removes every entry.

1. Run **Run checks**. Every line should be ✓.
2. Do the steps below from your own wallet.
3. Open **Qualifiers** for today (UTC): your wallet should be listed with its volume.
4. Under Setup, **Reset promotion** `rehearsal-1`.
5. Save the real id.

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

1. Console → **Qualifiers**: pick yesterday (UTC). The table shows every address that
   traded, its volume valued like the Dashboard, and ✓ at or above the qualifier. Look
   at any `unsized` rows (fills the book could not price) before deciding. Our fillers
   and the Setup exclusion list are left out.
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
6. When about 100 USDRIF has been paid out: Setup → **Switch off**.

## 5. Close

After the last payout or forfeit, pull the feedback for the freeze-backlog triage.
The form collects no contact details, so there is nothing personal to delete.

Use **Download CSV** under Feedback, or call `GET /raffle/admin/entries`.

Use **Switch off** on the console; the app hides the notice as soon as the desk says it is not live.
