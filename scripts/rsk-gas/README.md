# Rootstock fill-gas simulation

- `reprice.py` re-prices a `cast run --trace-printer` trace (revm, Cancun schedule) to
  Rootstock's schedule. The schedule was measured on mainnet with `eth_estimateGas`
  (RskJ 9.0.3):
  - SLOAD 200;
  - SSTORE priced by the CURRENT value: 20k for 0 → x, else 5k; a write to 0 refunds
    15k, capped at gasUsed / 2;
  - CALL family 700; EXTCODESIZE 700; BALANCE 400;
  - no cold/warm surcharges;
  - calldata 16 / 4 per byte.

  It reproduced every live beta fill receipt to the gas unit: 236,601, 258,692,
  281,345 and 409,065.
- `sim.sh` forks mainnet in anvil, deploys core + solver, and lets the real filler
  (`beta-filler fill-json`) fill app-shaped orders. `packages/beta-filler/e2e/sim-order.ts`
  builds them: fill-once, packed nonce, the chosen funding. Each fill is re-priced.

## Results (2026-10-12, retain mode, solver seeded by a warm-up fill)

| case | RSK gas |
|---|---|
| direct WRBTC→USD0, repeat maker, direct approval | 203,965 |
| same, Permit3 funding | 208,030 |
| direct, the maker's first trade | 234,912 |
| first fill on a fresh solver | 250,139 |
| pull WRBTC→USD0, repeat maker | 264,795 |
| direct 2-hop WRBTC→USD0→USDRIF, repeat | 269,362 |
| same, first USDRIF received | 284,346 |
| direct USD0→WRBTC, repeat, direct approval | 215,499 |
| same, gasless (ERC-2612 permit in the fill), repeat | 256,509 |
| gasless, the maker's first trade | 301,507 |
| pull USDRIF→USD0, repeat | 254,447 |
| pull USDRIF→USD0, first | 299,966 |

**Readings:**
- **Pull vs direct:** pull costs about +60k over direct. The settlement pulls the
  output from the solver, which needs an approve and a reset.
- **Permit in the fill:** about +41k measured; `PERMIT_IN_FILL_GAS` assumes 60k.
- **A maker's first trade:** +30–45k, from new balance, nonce-word and permit-nonce
  slots.
- **Order size:** tickets were 0.01 WRBTC / 800 USD, because anvil prices gas at 1 gwei.
  A larger ticket can cross more ticks, so small tickets may come in slightly lower.
