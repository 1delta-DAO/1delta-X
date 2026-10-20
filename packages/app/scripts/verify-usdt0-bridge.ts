/**
 * Re-checks the pinned USD₮0 on-ramp table (src/config/bridge.ts) against the chains:
 *
 *   • each source OFT's `token()` is the pinned token, `approvalRequired()` is read;
 *   • its peer for Rootstock (EID 30333) is the pinned Rootstock OFT;
 *   • the Rootstock OFT's peer for the source EID is the source OFT back;
 *   • the Rootstock OFT's `token()` is the USD₮0 the markets pin;
 *   • a 10 USD₮0 `quoteOFT` to Rootstock credits ≥ 99.5 % (no surprise fee).
 *
 * Public RPCs (`sourceRpc`: the pinned override, else viem's chain default). Run before every deploy that touches the table:
 *   pnpm --filter @1delta-x/app verify-bridge
 */
import { createPublicClient, http, type Address, type Hex } from "viem";
import { rootstock } from "viem/chains";

import { BRIDGE_SOURCES, ROOTSTOCK_USDT0, sourceRpc } from "../src/config/bridge";
import { minReceived, OFT_ABI, sendParamFor, toBytes32 } from "../src/lib/bridge";

const PROBE: Address = "0x000000000000000000000000000000000000dEaD";
const rsk = createPublicClient({ chain: rootstock, transport: http(undefined, { timeout: 20_000 }) });

let failed = 0;
const fail = (msg: string) => {
  failed++;
  console.log(`  ✗ ${msg}`);
};

const rskToken = (await rsk.readContract({ address: ROOTSTOCK_USDT0.oft, abi: OFT_ABI, functionName: "token" })) as Address;
console.log(`Rootstock OFT ${ROOTSTOCK_USDT0.oft} token() = ${rskToken}`);
if (rskToken.toLowerCase() !== ROOTSTOCK_USDT0.token) fail("Rootstock OFT token() is not the pinned USD₮0");

for (const src of BRIDGE_SOURCES) {
  console.log(`${src.label} (chain ${src.chain.id}, eid ${src.eid})`);
  try {
    const c = createPublicClient({ chain: src.chain, transport: http(sourceRpc(src), { timeout: 20_000, retryCount: 1 }) });
    const [token, approval, peer, back] = await Promise.all([
      c.readContract({ address: src.oft, abi: OFT_ABI, functionName: "token" }) as Promise<Address>,
      c.readContract({ address: src.oft, abi: OFT_ABI, functionName: "approvalRequired" }) as Promise<boolean>,
      c.readContract({ address: src.oft, abi: OFT_ABI, functionName: "peers", args: [ROOTSTOCK_USDT0.eid] }) as Promise<Hex>,
      rsk.readContract({ address: ROOTSTOCK_USDT0.oft, abi: OFT_ABI, functionName: "peers", args: [src.eid] }) as Promise<Hex>,
    ]);
    if (token.toLowerCase() !== src.token) fail(`token() ${token} ≠ pinned ${src.token}`);
    if (peer.toLowerCase() !== toBytes32(ROOTSTOCK_USDT0.oft)) fail(`peer(30333) ${peer} ≠ Rootstock OFT`);
    if (back.toLowerCase() !== toBytes32(src.oft)) fail(`Rootstock peer(${src.eid}) ${back} ≠ ${src.oft}`);
    const amount = 10n * 10n ** BigInt(src.decimals);
    const [, , receipt] = (await c.readContract({ address: src.oft, abi: OFT_ABI, functionName: "quoteOFT", args: [sendParamFor(PROBE, amount)] })) as readonly [unknown, unknown, { amountReceivedLD: bigint }];
    const ok = minReceived(amount, receipt.amountReceivedLD) !== null;
    if (!ok) fail(`quoteOFT credits ${receipt.amountReceivedLD} of ${amount}`);
    const fee = (await c.readContract({ address: src.oft, abi: OFT_ABI, functionName: "quoteSend", args: [sendParamFor(PROBE, amount, receipt.amountReceivedLD), false] })) as { nativeFee: bigint };
    console.log(`  token ✓  approvalRequired=${approval}  peers ✓  10 → ${receipt.amountReceivedLD}  fee ${Number(fee.nativeFee) / 1e18} ${src.chain.nativeCurrency.symbol}`);
  } catch (e) {
    fail(`unreachable or reverted: ${(e as Error).message.split("\n")[0]}`);
  }
}

if (failed) {
  console.log(`\n${failed} check(s) FAILED — do not ship the table as is.`);
  process.exit(1);
}
console.log("\nall pinned routes verified");
