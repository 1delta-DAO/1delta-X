import { isAddress, type Address, type Hex } from "viem";

import type { SoftCancel } from "./softcancel";
import type { CurvePoint, Item, LegIn, LegOut, Order, Validator } from "./types";

/**
 * JSON request bodies for `POST /orders` and `POST /cancels`.
 *
 * Browsers that run under a strict CSP (no `'unsafe-eval'`) cannot use the
 * protobuf codec — protobufjs compiles its encoders with `new Function` — so the
 * two maker-facing writes also accept `content-type: application/json`:
 *
 *   POST /orders   { "order": Order, "sig": "0x…" }
 *   POST /cancels  { "cancel": SoftCancel, "sig": "0x…" }
 *
 * The shapes are the SDK's `Order` / `SoftCancel` with every `bigint` as a
 * DECIMAL STRING (`"1000"`, never a number, never hex), addresses as `0x` + 40 hex
 * (all-lowercase or correctly checksummed), and `bytes` as even-length `0x` hex.
 *
 * This module lives in the SDK (it used to be `orderbook-server/src/json.ts`) so
 * every JSON consumer — the Node server, the Cloudflare Worker orderbook (which
 * cannot load protobufjs at all), the app and the filler — parses and prints the
 * SAME shape with the same rules.
 *
 * Parsing is STRICT: an unknown key, a missing required key, or a value of the
 * wrong type is a {@link JsonBodyError} (→ 400), never coerced. The result is the
 * same `OrderAnnounce` / `SignedSoftCancel` the protobuf decoder produces; the
 * route then re-encodes it to protobuf and decodes that, so both content types
 * reach every later check with byte-identical input.
 */
export class JsonBodyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "JsonBodyError";
  }
}

const UINT256_MAX = (1n << 256n) - 1n;
const DECIMAL = /^(0|[1-9][0-9]{0,77})$/;
const BYTES = /^0x(?:[0-9a-fA-F]{2})*$/;
const BYTES32 = /^0x[0-9a-fA-F]{64}$/;

type Obj = Record<string, unknown>;

function fail(path: string, what: string): never {
  throw new JsonBodyError(`${path}: ${what}`);
}

/** A plain object with exactly the allowed keys, all `required` ones present. */
function object(v: unknown, path: string, required: readonly string[], optional: readonly string[] = []): Obj {
  if (typeof v !== "object" || v === null || Array.isArray(v)) fail(path, "expected an object");
  const o = v as Obj;
  const allowed = new Set([...required, ...optional]);
  for (const k of Object.keys(o)) if (!allowed.has(k)) fail(`${path}.${k}`, "unknown field");
  for (const k of required) if (!(k in o)) fail(`${path}.${k}`, "missing");
  return o;
}

function array(v: unknown, path: string): unknown[] {
  if (!Array.isArray(v)) fail(path, "expected an array");
  return v;
}

function uint256(v: unknown, path: string): bigint {
  if (typeof v !== "string" || !DECIMAL.test(v)) fail(path, "expected a uint256 as a decimal string");
  const n = BigInt(v);
  if (n > UINT256_MAX) fail(path, "exceeds uint256");
  return n;
}

function uint32(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 0xffffffff) fail(path, "expected a uint32 number");
  return v;
}

function address(v: unknown, path: string): Address {
  if (typeof v !== "string" || !isAddress(v)) fail(path, "expected an address (lowercase or valid checksum)");
  return v as Address;
}

function bytes(v: unknown, path: string): Hex {
  if (typeof v !== "string" || !BYTES.test(v)) fail(path, "expected 0x-prefixed even-length hex");
  return v as Hex;
}

function bytes32(v: unknown, path: string): Hex {
  if (typeof v !== "string" || !BYTES32.test(v)) fail(path, "expected a 32-byte 0x hash");
  return v as Hex;
}

function legIn(v: unknown, path: string): LegIn {
  const o = object(v, path, ["token", "start", "end"]);
  return { token: address(o.token, `${path}.token`), start: uint256(o.start, `${path}.start`), end: uint256(o.end, `${path}.end`) };
}

function legOut(v: unknown, path: string): LegOut {
  const o = object(v, path, ["token", "start", "end", "recipient"]);
  return {
    token: address(o.token, `${path}.token`),
    start: uint256(o.start, `${path}.start`),
    end: uint256(o.end, `${path}.end`),
    recipient: address(o.recipient, `${path}.recipient`),
  };
}

function curvePoint(v: unknown, path: string): CurvePoint {
  const o = object(v, path, ["timeDelta", "bumpBps"]);
  return { timeDelta: uint32(o.timeDelta, `${path}.timeDelta`), bumpBps: uint32(o.bumpBps, `${path}.bumpBps`) };
}

function item(v: unknown, path: string): Item {
  const o = object(v, path, ["op", "module", "amount", "recipient", "data"]);
  return {
    op: uint32(o.op, `${path}.op`),
    module: address(o.module, `${path}.module`),
    amount: uint256(o.amount, `${path}.amount`),
    recipient: address(o.recipient, `${path}.recipient`),
    data: bytes(o.data, `${path}.data`),
  };
}

function validator(v: unknown, path: string): Validator {
  const o = object(v, path, ["target", "data"]);
  return { target: address(o.target, `${path}.target`), data: bytes(o.data, `${path}.data`) };
}

const ORDER_REQUIRED = [
  "maker", "side", "nonce", "expiry", "legsIn", "legsOut", "timing", "exclusiveFiller", "minFillAnchor",
  "exclusivityOverrideBps", "curve", "gasBumpBps", "gasPriceRef", "priorityScale", "items", "validators",
  "invariants", "fillModule", "fillTotal", "pricingModule",
] as const;

/** The SDK `Order`, from its JSON form. */
export function orderFromJson(v: unknown, path = "order"): Order {
  const o = object(v, path, ORDER_REQUIRED, ["baselinePriorityFeeWei"]);
  if (o.side !== 0 && o.side !== 1) fail(`${path}.side`, "expected 0 (SELL) or 1 (BUY)");
  const list = <T>(key: string, each: (x: unknown, p: string) => T): T[] =>
    array(o[key], `${path}.${key}`).map((x, i) => each(x, `${path}.${key}[${i}]`));
  return {
    maker: address(o.maker, `${path}.maker`),
    side: o.side,
    nonce: uint256(o.nonce, `${path}.nonce`),
    expiry: uint256(o.expiry, `${path}.expiry`),
    legsIn: list("legsIn", legIn),
    legsOut: list("legsOut", legOut),
    timing: uint256(o.timing, `${path}.timing`),
    exclusiveFiller: address(o.exclusiveFiller, `${path}.exclusiveFiller`),
    minFillAnchor: uint256(o.minFillAnchor, `${path}.minFillAnchor`),
    exclusivityOverrideBps: uint256(o.exclusivityOverrideBps, `${path}.exclusivityOverrideBps`),
    curve: list("curve", curvePoint),
    gasBumpBps: uint256(o.gasBumpBps, `${path}.gasBumpBps`),
    gasPriceRef: uint256(o.gasPriceRef, `${path}.gasPriceRef`),
    priorityScale: uint256(o.priorityScale, `${path}.priorityScale`),
    ...(o.baselinePriorityFeeWei !== undefined
      ? { baselinePriorityFeeWei: uint256(o.baselinePriorityFeeWei, `${path}.baselinePriorityFeeWei`) }
      : {}),
    items: list("items", item),
    validators: list("validators", validator),
    invariants: list("invariants", validator),
    fillModule: address(o.fillModule, `${path}.fillModule`),
    fillTotal: uint256(o.fillTotal, `${path}.fillTotal`),
    pricingModule: address(o.pricingModule, `${path}.pricingModule`),
  };
}

/** A signed order as it travels in JSON: the SDK `Order` plus the maker's signature. */
export interface SignedOrderJson {
  order: Order;
  sig: Hex;
}

/** A maker-signed soft cancel as it travels in JSON. */
export interface SignedSoftCancelJson {
  cancel: SoftCancel;
  sig: Hex;
}

/** `{ order, sig }` → `{ order, sig }` (structurally the orderbook's `OrderAnnounce`). Throws {@link JsonBodyError}. */
export function announceFromJson(v: unknown): SignedOrderJson {
  const o = object(v, "body", ["order", "sig"]);
  return { order: orderFromJson(o.order), sig: bytes(o.sig, "body.sig") };
}

/** `{ cancel, sig }` → `{ cancel, sig }` (structurally the orderbook's `SignedSoftCancel`). Throws {@link JsonBodyError}. */
export function softCancelFromJson(v: unknown): SignedSoftCancelJson {
  const o = object(v, "body", ["cancel", "sig"]);
  const c = object(o.cancel, "cancel", ["maker", "orderHashes", "issuedAt", "expiry"]);
  const cancel: SoftCancel = {
    maker: address(c.maker, "cancel.maker"),
    orderHashes: array(c.orderHashes, "cancel.orderHashes").map((h, i) => bytes32(h, `cancel.orderHashes[${i}]`)),
    issuedAt: uint256(c.issuedAt, "cancel.issuedAt"),
    expiry: uint256(c.expiry, "cancel.expiry"),
  };
  return { cancel, sig: bytes(o.sig, "body.sig") };
}

/**
 * The SDK `Order` as the plain JSON value {@link orderFromJson} accepts: every
 * bigint a decimal string, only the `Order` fields, in a FIXED key order — so two
 * encoders of one order emit byte-identical text. The inverse of {@link orderFromJson}.
 */
export function orderToJson(o: Order): Record<string, unknown> {
  const s = (n: bigint): string => n.toString();
  return {
    maker: o.maker,
    side: o.side,
    nonce: s(o.nonce),
    expiry: s(o.expiry),
    legsIn: o.legsIn.map((l) => ({ token: l.token, start: s(l.start), end: s(l.end) })),
    legsOut: o.legsOut.map((l) => ({ token: l.token, start: s(l.start), end: s(l.end), recipient: l.recipient })),
    timing: s(o.timing),
    exclusiveFiller: o.exclusiveFiller,
    minFillAnchor: s(o.minFillAnchor),
    exclusivityOverrideBps: s(o.exclusivityOverrideBps),
    curve: o.curve.map((c) => ({ timeDelta: c.timeDelta, bumpBps: c.bumpBps })),
    gasBumpBps: s(o.gasBumpBps),
    gasPriceRef: s(o.gasPriceRef),
    priorityScale: s(o.priorityScale),
    ...(o.baselinePriorityFeeWei !== undefined ? { baselinePriorityFeeWei: s(o.baselinePriorityFeeWei) } : {}),
    items: o.items.map((i) => ({ op: i.op, module: i.module, amount: s(i.amount), recipient: i.recipient, data: i.data })),
    validators: o.validators.map((v) => ({ target: v.target, data: v.data })),
    invariants: o.invariants.map((v) => ({ target: v.target, data: v.data })),
    fillModule: o.fillModule,
    fillTotal: s(o.fillTotal),
    pricingModule: o.pricingModule,
  };
}

/** A {@link SoftCancel} as the plain JSON value {@link softCancelFromJson} accepts under `cancel`. */
export function softCancelToJson(c: SoftCancel): Record<string, unknown> {
  return { maker: c.maker, orderHashes: [...c.orderHashes], issuedAt: c.issuedAt.toString(), expiry: c.expiry.toString() };
}
