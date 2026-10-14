# 29. Filler: buy BTC from users through Money on Chain's DOC (native RBTC in)

- **Status:** open (planned 2026-10-14)
- **Layer:** filler (+ app copy only)
- **Package:** `packages/beta-filler`, `packages/filler-worker`; `packages/app` (wording only)
- **Severity:** feature: better prices for BTC sellers
- **Opened:** 2026-10-14
- **Deployments:** none. No new contract, and the app auto-wraps native RBTC today.

## Problem

A user selling BTC for USD₮0 gets the WRBTC/USD₮0 pool price. That pool trades about 1 %
under Money on Chain's BTC oracle ($80.9k against $81.7k on 2026-10-14).

Money on Chain v1 mints DOC at the oracle price for a 0.15 % commission, settled in the
same transaction. The DOC/USD₮0 pool is deep: −0.59 % at 500 DOC, −0.68 % at 20,000 DOC.
Minting DOC and selling it beats the WRBTC pool after gas:

| Size | Gain |
| --- | --- |
| $500 | +0.30 % |
| $2,000 | +0.65 % |
| $10,000 | +1.36 % |
| $25,000 | +2.59 % |

A fork run on 2026-10-14 confirmed:

- `mintDocVendors` and `redeemFreeDocVendors` execute immediately, and excess RBTC is refunded.
- The commission rates read on-chain are 0.15 % paid in RBTC and 0.10 % paid in MOC.
- Gas is about 454k for a mint and about 408k for a redemption (≈ $1 each on Rootstock).
- A caller must be able to receive native RBTC. The solver contract cannot, and reverts with
  "RBTC transfer failed". The operator EOA can.

Addresses: MoC `0xf773…8370`, MoCState `0xb9C4…e257`, MoCInrate `0xc0f9…A3F3`, DOC `0xe700…D9Db`.

## Native RBTC: already covered

Native RBTC input already works in the app: `lib/funding.ts` `planFunding` auto-wraps.

- An order selling WRBTC whose WRBTC balance falls short wraps exactly the shortfall
  (`WRBTC.deposit`, 43k gas ≈ $0.10).
- It always keeps `WRAP_GAS_RESERVE_WEI` (0.00005 RBTC) for gas.
- Spendable balance counts native RBTC (`wrapSpendableWei`).

The filler therefore always receives WRBTC and never needs a native input leg. A
one-transaction native path, with no wrap transaction, would need an escrow contract
(EthFlow shape, see memory native-asset-core-assessment). That is a new deployment and not
worth $0.10 a trade.

## Change

1. **New inventory direction:** WRBTC → USD₮0. The maker sells WRBTC and we pay USD₮0 from
   the wallet.
   - Value of the WRBTC received: `oracle × (1 − 0.15 %)` DOC, then quoted DOC → USD₮0 on
     the pool (exact in).
   - Subtract the conversion gas (unwrap + mint + swap ≈ 600k).
   - Quote source: `moc-doc`. Never spend `USDT0_RESERVE`.
2. **Guards on every quote and fill:**
   - MoC is not paused.
   - The DOC mint fits under its caps: read `absoluteMaxDoc` and the free DOC / coverage
     limits, and confirm on a fork which one binds a mint.
   - The oracle price is fresh, since `getBitcoinPrice` reverts when stale.
3. **Conversion right after the fill**, one transaction per step, in the rebalancer:
   1. `WRBTC.withdraw`.
   2. `mintDocVendors{value}(btc, 0x0)`; the refund goes to the EOA.
   3. DOC → USD₮0 on the 0.3 % pool, with a peg guard and a slippage floor.

   The wallet holds BTC for a few ticks at most. If MoC refuses the mint, fall back to
   WRBTC → USD₮0 on the pool so the position always closes.
4. **App:** wording only. Show "Money on Chain" as the source, as the RIF rail does.
5. **Tests:**
   - Unit: pricing, guards, the conversion state machine.
   - Fork: extend `e2e/rail-fork.sh` with a native seller. The app path is wrap + sign; on
     the fork, the filler fills it and then runs unwrap → mint → swap.
6. **Later, and only if wanted:**
   - BTC **buys** through DOC redemption only win at about $10k or more today.
   - Receiving native RBTC is task 28 and needs the `NativeUnwrapModule` deployment.

## Acceptance

- A WRBTC → USD₮0 quote from the wallet beats the route at $500 or more while the pool sits
  under the oracle, and loses cleanly otherwise.
- The fork run fills a native seller's order and converts it back to USD₮0 within two ticks.
- No fill goes out while MoC is paused, stale, or over its cap.
