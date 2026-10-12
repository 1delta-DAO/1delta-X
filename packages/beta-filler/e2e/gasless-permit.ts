/**
 * Fork e2e (LOCAL ONLY, NOT part of CI): gasless maker funding with an ERC-2612
 * permit carried IN the fill, against the Rootstock beta contracts on an anvil fork.
 *
 *   anvil --fork-url https://public-node.rsk.co --port 18645 --gas-price 0 --block-base-fee-per-gas 0
 *   # the pool-route + permits AggregatorFillSolver must exist on the fork — deploy it
 *   # there (`make deploy-aggregator-fill` against the anvil RPC, OPERATORS = OPERATOR)
 *   # until the live beta instance is redeployed:
 *   RPC_URL=http://127.0.0.1:18645 AGGREGATOR_SOLVER=0x… [OPERATOR=0x…] npx tsx e2e/gasless-permit.ts
 *
 * A fresh maker holding only USD₮0 (no RBTC, no approvals, never sends a tx):
 *   1. signs an order and a USD₮0 `permit(maker, Settlement, value, nonce, deadline = expiry)`;
 *   2. the orderbook Verifier admits it on the live permit (lens fillable 0);
 *   3. the filler's permit stage says "permit" (fill WITH it), sized from the permit;
 *   4. ONE tx: the operator's `executeFill(…, permits = [the maker's permit])` on a
 *      direct pool plan (Oku WRBTC/USD₮0, venue 0) — the solver runs the permit, then
 *      the fill; without the permit the same call reverts;
 *   5. front-run: a second permit is relayed by a third party first; the stage flips to
 *      "funded" (the filler would now send no permit) and an executeFill that still
 *      carries the spent permit succeeds anyway — the solver accepts an existing
 *      allowance ≥ value.
 * Prints the fill gas with the in-fill permit (what PERMIT_IN_FILL_GAS prices).
 */
import {
  AGGREGATOR_FILL_SOLVER_ABI,
  ERC2612_ABI,
  OrderSide,
  QUOTER_V2_ABI,
  SETTLEMENT_LENS_ABI,
  encodeAggregatorExecuteFill,
  encodeErc2612Permit,
  encodeV3Path,
  erc2612DomainOf,
  erc2612DomainSeparator,
  erc2612TypedData,
  packOrder,
  packTiming,
  randomOrderNonce,
  signOrder,
  splitPermitSignature,
  toSolverPermit,
  type Erc2612Permit,
  type Order,
  type RoutePlan,
} from "@1delta-x/sdk";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeFunctionData,
  erc20Abi,
  getAddress,
  http,
  keccak256,
  numberToHex,
  pad,
  parseEther,
  toHex,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { Verifier } from "../../orderbook/src/verify";
import { connect } from "../src/chain";
import { loadConfig, ROOTSTOCK } from "../src/config";
import { permitStage } from "../src/permit";
import { buildPoolPlan, validatePoolPlan } from "../src/route";

const RPC = process.env.RPC_URL ?? "http://127.0.0.1:18645";
// docs/deployment-rootstock-beta.md
const PERMIT3 = getAddress("0xabaefb5ae495Dcbce40d1e057346f31A500668a8");
const SETTLEMENT = getAddress("0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5");
const LENS = getAddress("0xF9e905EdCC376FDaBF62Ca0966624611721C5206");
// The live beta instance (0x33cc…E287) predates pool plans and `permits`: pass the
// redeployed one. OPERATOR must be in its operator set (impersonated on the fork).
const SOLVER = getAddress(process.env.AGGREGATOR_SOLVER ?? "0x33ccAcb24DA5c7f335819Da877FC03E4bf62E287");
const OPERATOR = getAddress(process.env.OPERATOR ?? "0xcafe35944e3195d59b4a354Ea23D60a0445c083a");
const USDT0 = getAddress(ROOTSTOCK.usdt0);
const WRBTC = getAddress(ROOTSTOCK.wrbtc);

const chain = defineChain({ id: 30, name: "rsk-fork", nativeCurrency: { name: "RBTC", symbol: "RBTC", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC, { retryCount: 3 }) }) as PublicClient;
const rpc = <T>(method: string, params: unknown[]) => pub.request({ method: method as never, params: params as never }) as Promise<T>;

const makerKey = keccak256(toHex("1delta-gasless-permit:maker"));
const maker = privateKeyToAccount(makerKey);
const relayer = privateKeyToAccount(keccak256(toHex("1delta-gasless-permit:relayer")));

function ok(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`✗ ${msg}`);
  console.log(`✓ ${msg}`);
}

async function send(from: Address | ReturnType<typeof privateKeyToAccount>, to: Address, data: Hex, value = 0n) {
  const w = createWalletClient({ chain, transport: http(RPC), account: from as never });
  const hash = await w.sendTransaction({ to, data, value, chain, gasPrice: 0n } as never);
  return pub.waitForTransactionReceipt({ hash });
}

/** `deal` by storage write (anvil_dealERC20 finds no slot on the USD₮0 proxy) — as filler-worker/e2e/lib.ts. */
async function deal(token: Address, who: Address, amount: bigint): Promise<void> {
  const data = encodeFunctionData({ abi: erc20Abi, functionName: "balanceOf", args: [who] });
  const al = await rpc<{ accessList: Array<{ address: Address; storageKeys: Hex[] }> }>("eth_createAccessList", [{ to: token, data }, "latest"]);
  const skip = new Set(["0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"]);
  for (const e of al.accessList) {
    for (const slot of e.storageKeys) {
      if (skip.has(slot.toLowerCase())) continue;
      const prev = (await pub.getStorageAt({ address: e.address, slot })) ?? pad("0x0", { size: 32 });
      await rpc("anvil_setStorageAt", [e.address, slot, pad(numberToHex(amount), { size: 32 })]);
      if ((await pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] })) === amount) return;
      await rpc("anvil_setStorageAt", [e.address, slot, prev]);
    }
  }
  throw new Error("deal: no slot");
}

const bal = (t: Address, who: Address) => pub.readContract({ address: t, abi: erc20Abi, functionName: "balanceOf", args: [who] });
const allowance = (who: Address) => pub.readContract({ address: USDT0, abi: erc20Abi, functionName: "allowance", args: [who, SETTLEMENT] });
const nonceOf = (who: Address) => pub.readContract({ address: USDT0, abi: ERC2612_ABI, functionName: "nonces", args: [who] });

async function sellOrder(amountIn: bigint, pricePct: bigint): Promise<{ order: Order; sig: Hex; owed: bigint }> {
  const { result } = await pub.simulateContract({ address: ROOTSTOCK.quoterV2 as Address, abi: QUOTER_V2_ABI, functionName: "quoteExactInput", args: [encodeV3Path([USDT0, WRBTC], [3000]), amountIn] });
  const owed = (result[0] * pricePct) / 100n;
  const now = (await pub.getBlock()).timestamp;
  const order: Order = {
    maker: maker.address, side: OrderSide.SELL, nonce: randomOrderNonce(0n), expiry: now + 3600n,
    legsIn: [{ token: USDT0, start: amountIn, end: 0n }],
    legsOut: [{ token: WRBTC, start: owed, end: 0n, recipient: zeroAddress }],
    timing: packTiming(0, 0, 0), exclusiveFiller: zeroAddress, minFillAnchor: 0n, exclusivityOverrideBps: 0n, curve: [],
    gasBumpBps: 0n, gasPriceRef: 0n, priorityScale: 0n, items: [], validators: [], invariants: [],
    fillModule: zeroAddress, fillTotal: 0n, pricingModule: zeroAddress,
  };
  const sig = await signOrder(maker, order, { chainId: 30, settlement: SETTLEMENT, permit3: PERMIT3 });
  return { order, sig, owed };
}

async function signPermit(order: Order, value: bigint): Promise<Erc2612Permit> {
  const domain = erc2612DomainOf(30, USDT0)!;
  const nonce = await nonceOf(maker.address);
  const sig = await maker.signTypedData(erc2612TypedData(domain, { owner: maker.address, spender: SETTLEMENT, value, nonce, deadline: order.expiry }));
  return { token: USDT0, spender: SETTLEMENT, value, nonce, deadline: order.expiry, ...splitPermitSignature(sig) };
}

// ── setup ──────────────────────────────────────────────────────────────────
ok((await pub.getChainId()) === 30, "fork is chain 30");
ok((await pub.readContract({ address: USDT0, abi: ERC2612_ABI, functionName: "DOMAIN_SEPARATOR" })) === erc2612DomainSeparator(erc2612DomainOf(30, USDT0)!), "USD₮0 DOMAIN_SEPARATOR equals the pinned (USD₮0, 1, 30, token) domain");
const venues = await pub.readContract({ address: SOLVER, abi: AGGREGATOR_FILL_SOLVER_ABI, functionName: "POOL_VENUES" }).catch(() => undefined);
ok(venues !== undefined && venues > 0n, `solver ${SOLVER} has pool venues (POOL_VENUES = ${venues}) — the pool-route + permits version`);
await deal(USDT0, maker.address, 50_000_000n); // 50 USD₮0, and NO RBTC
ok((await pub.getBalance({ address: maker.address })) === 0n, "maker holds no RBTC");
await rpc("anvil_setBalance", [relayer.address, numberToHex(parseEther("1"))]);
await rpc("anvil_impersonateAccount", [OPERATOR]);
await rpc("anvil_setBalance", [OPERATOR, numberToHex(parseEther("1"))]);

const cfg = loadConfig({ PRIVATE_KEY: keccak256(toHex("1delta-gasless-permit:filler-cfg")), SETTLEMENT, PERMIT3, LENS, ORDERBOOK_URL: "http://unused.invalid", RPC_URL: RPC, INVENTORY_ENABLED: "0", AGGREGATOR_SOLVER: SOLVER });
const fc = connect(cfg);
const blockTime = async () => (await pub.getBlock()).timestamp;

/** The pull pool plan the route strategy builds for `order` (Oku WRBTC/USD₮0, venue 0, no margin kept). */
async function pullPlan(order: Order, fillAmount: bigint): Promise<RoutePlan> {
  const [, received, paid] = (await pub.readContract({ address: LENS, abi: SETTLEMENT_LENS_ABI, functionName: "previewFill", args: [packOrder(order) as never, fillAmount, SOLVER, "0x"] })) as readonly [bigint, readonly bigint[], readonly bigint[]];
  const path = { tokens: [USDT0, WRBTC], fees: [3000], venue: 0 };
  const { result: q } = await pub.simulateContract({ address: ROOTSTOCK.quoterV2 as Address, abi: QUOTER_V2_ABI, functionName: "quoteExactInput", args: [encodeV3Path(path.tokens, path.fees), received[0]!] });
  const { plan } = buildPoolPlan({ direct: false, path, received: received[0]!, owed: paid[0]!, quotedOut: q[0], costOut: 0n, profitRecipient: OPERATOR, minBumpBps: 0n });
  const v = validatePoolPlan(plan, order, { direct: false, path, received: received[0]!, owed: paid[0]! });
  ok(v.ok, `pool plan validates against the order${v.ok ? "" : `: ${v.reason}`}`);
  return plan;
}

// ── 1. order + permit ─────────────────────────────────────────────────────
const A = await sellOrder(10_000_000n, 97n);
const pA = await signPermit(A.order, 10_000_000n);

// ── 2. the book admits it on the permit ──────────────────────────────────
const verifier = new Verifier(pub, { chainId: 30, settlement: SETTLEMENT, permit3: PERMIT3, lens: LENS, rpcUrl: RPC });
const chk = await verifier.checkErc2612(A.order, pA);
ok(chk.ok && chk.live, "Verifier.checkErc2612 on the real token: ok + live");
const admitted = await verifier.verifyAnnounce({ order: A.order, sig: A.sig, erc2612Permit: pA });
ok(admitted.ok && admitted.state?.erc2612Live === true && admitted.state.fillableAmount === 0n, `book admits it unfunded on the permit (lens fillable ${admitted.state?.fillableAmount})`);
const without = await verifier.verifyAnnounce({ order: A.order, sig: A.sig });
ok(!without.ok, `without the permit the book refuses it (${without.reason})`);

// ── 3. the filler's stage ────────────────────────────────────────────────
const entryA = { orderHash: admitted.orderHash, announce: { order: A.order, sig: A.sig, erc2612Permit: pA } };
const s1 = await permitStage(fc, cfg, entryA, await blockTime());
ok(s1.kind === "permit" && s1.fillable === 10_000_000n, `filler permit stage: ${s1.kind}${s1.kind === "permit" ? ` (fillable ${s1.fillable})` : ""}`);

// ── 4. ONE tx: executeFill carrying the permit ───────────────────────────
const planA = await pullPlan(A.order, 10_000_000n);
const bare = encodeAggregatorExecuteFill({ order: A.order, sig: A.sig, fillAmount: 10_000_000n, plan: planA });
let bareReverted = false;
try {
  await pub.call({ account: OPERATOR, to: SOLVER, data: bare });
} catch {
  bareReverted = true;
}
ok(bareReverted, "without the permit the same executeFill reverts (nothing funds the pull)");
const withPermit = encodeAggregatorExecuteFill({ order: A.order, sig: A.sig, fillAmount: 10_000_000n, plan: planA, permits: [toSolverPermit(maker.address, pA, SETTLEMENT)] });
const wrbtcBefore = await bal(WRBTC, maker.address);
const usdt0Before = await bal(USDT0, maker.address);
const rA = await send(OPERATOR, SOLVER, withPermit);
ok(rA.status === "success", `executeFill WITH the maker's permit succeeded in one tx — gasUsed ${rA.gasUsed}`);
ok(usdt0Before - (await bal(USDT0, maker.address)) === 10_000_000n, "maker paid exactly 10 USD₮0 (pulled through the direct allowance the permit set)");
ok((await bal(WRBTC, maker.address)) - wrbtcBefore >= A.owed, `maker received ≥ ${A.owed} WRBTC`);
ok((await nonceOf(maker.address)) === pA.nonce + 1n, "token nonce advanced (the permit ran inside the fill)");
ok((await allowance(maker.address)) === 0n, "the direct allowance is used up");

// ── 5. front-run: the permit relayed by someone else first ───────────────
const B = await sellOrder(20_000_000n, 95n);
const pB = await signPermit(B.order, 20_000_000n);
const rRelay = await send(relayer, USDT0, encodeErc2612Permit(maker.address, pB));
ok(rRelay.status === "success", `a third party relays the second permit first — gasUsed ${rRelay.gasUsed}`);
const entryB = { orderHash: admitted.orderHash, announce: { order: B.order, sig: B.sig, erc2612Permit: pB } };
const s2 = await permitStage(fc, cfg, entryB, await blockTime());
ok(s2.kind === "funded" && s2.fillable > 0n, `filler permit stage after the relay: ${s2.kind} (the filler sends no permit now)`);
const planB = await pullPlan(B.order, 20_000_000n);
const stale = encodeAggregatorExecuteFill({ order: B.order, sig: B.sig, fillAmount: 20_000_000n, plan: planB, permits: [toSolverPermit(maker.address, pB, SETTLEMENT)] });
const rB = await send(OPERATOR, SOLVER, stale);
ok(rB.status === "success", `executeFill still carrying the SPENT permit succeeds (allowance ≥ value accepted) — gasUsed ${rB.gasUsed}`);
ok((await bal(WRBTC, maker.address)) - wrbtcBefore >= A.owed + B.owed, "maker received the owed WRBTC of both orders");
ok((await pub.getTransactionCount({ address: maker.address })) === 0, "the maker never sent a transaction");
console.log(`\nexecuteFill gas with the in-fill permit: ${rA.gasUsed} (PERMIT_IN_FILL_GAS prices the permit's share before simulation)`);
