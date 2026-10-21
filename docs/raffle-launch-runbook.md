# Prize draw + USD₮0 on-ramp — launch runbook

**Day to day, use the operator console. It is a separate Pages project (`packages/raffle-admin`, behind Cloudflare Access), not part of the app.** It needs the
orderbook worker's `RAFFLE_ADMIN_TOKEN`. It has four tabs:

- **Setup & tests**: configure, switch on/off, run checks, reset a promotion.
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
| 1 | TC.md is the reviewed 2 September 2026 text and must not change. The claim wording a winner signs (`CLAIM_STATEMENT` in `packages/sdk/src/participation.ts`) restates §3/§7.5/§8; show it to counsel if in doubt | — |
| 2 | Decide the promotion window and the support link | `PROMOTION.support` in `VITE_PROMOTION` (Telegram group or form URL) |
| 3 | Grant-thread commitments not in the app as of 2026-10-14 (per-user ~1,000 USDRIF cap, total cap, time-bounded allowances): ship them, or say in the thread why not, before promoting on the Collective | `docs/local/rootstock-grant-m1-checklist.md` |

TC.md must not change (reviewed). Its hash is `0xa10e1478676838587e36b9b6ca0c6d88996aeb40dbadd2d988e9e7631a7d1bd8`;
the console's **use it** fills it in.

### The live configuration (rootstock-beta-1)

| Setting | Value |
|---|---|
| Promotion id | `rootstock-beta-1` |
| Terms hash | `0xa10e1478…1bd8` (use it) |
| Starts | the announcement day, 00:00 UTC |
| Entries close | leave empty (the pot decides) |
| Draw every … days | 1 |
| Daily qualifier | $20 |
| Minimum qualifiers | 3 (fewer: the day's 10 USDRIF rolls to the next day) |
| Prizes per draw | 10 |
| Prize token | USDRIF |
| Total pot | 100 |
| One prize per address | on |
| Excluded from draws | the addresses below plus every team member's personal wallet |

Addresses to exclude (our fillers `0xcafe…083a`, `0x5987…6cD1`, `0x48db…32F1` are excluded automatically; list them anyway):

```
0x00001d4754680958E7f8fe42D60842Ebde4Cb30D   deployer
0xcafe35944e3195d59b4a354Ea23D60a0445c083a   filler operator (inventory / spot)
0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287   AggregatorFillSolver v1
0x48dbdC43507767BD51ec0AF2cb9bfa5E35B332F1   AggregatorFillSolver v2
0x5987A4AFE1b680DAC657506B69C56b06FFe86cD1   AggregatorFillSolver v3
0xdadE4B0F9dEa9f2CC371E07f76653971b2c62C04   RouteSandbox v1
0xda2Db66B3Ae47a1f5F89640666b7802423828c8b   RouteSandbox v2
0xeBbBf5719B699a450b2537852E4286A7e69Bb1aD   RouteSandbox v3
0xB6107a1DEa7Ae04129aBc27ce607249049f3C735   NativeUnwrapModule
```

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

## 3. Rehearsal, then the live end-to-end test

On the console, save a throwaway id such as `rehearsal-1` with the qualifier set to
$1. The rehearsal is public while it runs, so anyone could enter it, but a reset
removes every entry.

1. Run **Run checks**. Every line should be ✓.
2. Do the steps below from your own wallet.
3. Run a **Test draw** under Draws.
4. Under Setup, **Reset promotion** `rehearsal-1`.
5. Save the real id.

Steps from your wallet (real funds, small):

Do this from a fresh wallet that holds **no RBTC on Rootstock**:

1. Bridge 10 USD₮0 from Arbitrum to your address on Rootstock through **usdt0.to** (linked from the app). Expect about $1.2 in LayerZero fee and arrival in about 23 minutes. Track it on LayerZero Scan.
2. Open the app on Rootstock. Sell 5 USD₮0 for **RBTC** (market order), using the gasless permit path.
   - Expected: native RBTC arrives through solver v3 + NativeBalance, and the wallet never paid gas.
   - This combination (permit-funded order + native RBTC out) has not been filled live before. If it fails, RBTC delivery is the thing to fix.
3. After the fill is indexed (about 20 s), **Rate the app** appears. Fill in the form and sign. Expect the "Thank you" message.
4. Check that the feedback appears under **Feedback** on the console, and that the address shows up under Draws → Compute for the current period (it is in the draw without any form).

## 4. The draws (one per period, the morning after it ends)

**Compliance with the reviewed Terms (TC.md, 2 September 2026, unchanged):** there
is no registration (§4.1), so the draw lists EVERY wallet with qualifying fills,
whether or not it gave feedback; the feedback form is optional. The rules below are
"qualifying criteria communicated through official channels" (§4.2/4.3) and 1delta's
"number, timing and amount of prizes" (§6.2); the announcement line and the app notice
are that communication. A winner confirms eligibility before payout (§7.5) by signing
the claim in the app. The rules are console settings (Setup tab) and are published on
`GET /raffle`, so the app notice always states what the desk runs. Defaults match
what was announced (around 100 USDRIF over roughly ten daily draws; TC §2.1 says
daily draws too): a draw **every UTC day** from the start date, one ticket per day an
address trades ≥ $20, at least **3** qualifying addresses or the prize is carried to
the next day, **10 USDRIF** to one winner, one prize per address while others are
waiting; a **pot** of 100 USDRIF, so the draws continue until 100 has been paid
(ten paid days; quiet days roll over and make it longer). The console stops offering
draws once the pot is paid; then switch the promotion off.

On the console, Draws tab:

1. Pick the period that just ended (the newest one without a record is preselected) and **Compute**. Review the `unsized` column and the "set aside" list.
2. If fewer than the minimum qualified, press **Record carry-forward**. Nothing is drawn; the prize rides on the next period. Publish the announcement line anyway, so the carry is public.
3. Otherwise **Save & fix draw block**, then **publish** the announcement line (tickets, `listHash`, draw block) in the official channel **before that block** (about an hour).
4. After the block is 12 deep (about 6 minutes more), press **Draw**.
5. Publish the winners by address (TC §8.1). This is how a winner learns they won: the app then shows that wallet a **claim** button, and the claim (TC §3, §7.5 confirmations, Terms accepted by hash) is signed in the app. The window is 14 days; a winner who confirms another way is recorded under Support.
6. Review each claimed winner (TC §5, §7.5): funding-source clusters, wallet age, whether its only activity is our raffle. If a winner is excluded, **exclude …** redraws deterministically.
7. Pay claimed prizes from the treasury wallet, then publish the payout txs.

After the end date a **Final draw** option appears: it spends whatever was carried
forward and never paid, among addresses with ≥ 2 qualifying days overall. If even
that has fewer than the minimum, nothing is paid.

The CLI equivalent (records as JSON files, same rules):

```sh
cd packages/raffle-admin
pnpm raffle-draw snapshot --book https://<app>/api/book --exclude team.txt --out raffle/   # next period without a record
pnpm raffle-draw draw --snapshot raffle/<day>.json [--skip <address>]
pnpm raffle-draw snapshot --final --book https://<app>/api/book --out raffle/            # after the end date
```

`team.txt` lists the addresses of employees, contractors and ambassadors (TC §3.3;
ambassadors run on their own pool). One address per line. The console uses the
exclusion list from Setup instead.

## 5. Close

After the last payout or forfeit, pull the feedback for the freeze-backlog triage.
The form collects no contact details, so there is nothing personal to delete.

Use **Download CSV** under Feedback, or call `GET /raffle/admin/entries`.

Use **Switch off** on the console; the app hides the notice as soon as the desk says it is not live.
