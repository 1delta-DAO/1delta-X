import protobuf from "protobufjs";
import type { CurvePoint, Item, LegIn, LegOut, Order, PermitBatch, TakerPermit, TokenPermit, Validator } from "@1delta-x/sdk";
import { ItemOp, OrderSide } from "@1delta-x/sdk";
import { bytesToBigInt, bytesToHex, getAddress, hexToBytes, zeroAddress, type Address, type Hex } from "viem";

import type { FillNotice, OrderAnnounce, OrderSoftCancel } from "../messages";
import { SCHEMA, StreamKind } from "./schema";

// ──────────────────── schema (parsed once, at load) ────────────────────

const root = protobuf.parse(SCHEMA, { keepCase: true }).root;
root.resolveAll();
const P = "onedelta.orderbook.v1.";
const OrderAnnounceT = root.lookupType(`${P}OrderAnnounce`);
const OrderSoftCancelT = root.lookupType(`${P}OrderSoftCancel`);
const FillNoticeT = root.lookupType(`${P}FillNotice`);
const OrderListT = root.lookupType(`${P}OrderList`);
const StreamMessageT = root.lookupType(`${P}StreamMessage`);

// ──────────────────── scalar conversions ────────────────────

/** uint256 → big-endian, minimal bytes (0 ⇒ empty), so decode reconstructs it exactly. */
function u256ToBytes(v: bigint): Uint8Array {
  if (v < 0n) throw new Error("negative uint256");
  if (v === 0n) return new Uint8Array(0);
  let h = v.toString(16);
  if (h.length % 2) h = `0${h}`;
  return hexToBytes(`0x${h}` as Hex);
}
function bytesToU256(b: Uint8Array | undefined): bigint {
  return b && b.length > 0 ? bytesToBigInt(b) : 0n;
}
/** address → 20 fixed bytes (never minimized). */
function addrToBytes(a: Address): Uint8Array {
  return hexToBytes(getAddress(a));
}
function bytesToAddr(b: Uint8Array | undefined): Address {
  return b && b.length > 0 ? getAddress(bytesToHex(b)) : zeroAddress;
}
function hexToU8(h: Hex): Uint8Array {
  return hexToBytes(h);
}
function u8ToHex(b: Uint8Array | undefined): Hex {
  return b && b.length > 0 ? bytesToHex(b) : "0x";
}
/** protobufjs may hand back a Long, number, or string for a uint64 — normalize. */
function toNum(x: number | { toString(): string } | undefined): number {
  return x == null ? 0 : Number(typeof x === "number" ? x : x.toString());
}

// ──────────────────── wire shapes (structural view of decoded messages) ────────────────────

interface PbLegIn { token: Uint8Array; start: Uint8Array; end: Uint8Array }
interface PbLegOut { token: Uint8Array; start: Uint8Array; end: Uint8Array; recipient: Uint8Array }
interface PbCurvePoint { timeDelta: number; bumpBps: number }
interface PbItem { op: number; module: Uint8Array; amount: Uint8Array; recipient: Uint8Array; data: Uint8Array }
interface PbValidator { target: Uint8Array; data: Uint8Array }
interface PbOrder {
  maker: Uint8Array; side: number; nonce: Uint8Array; deadline: Uint8Array;
  legsIn: PbLegIn[]; legsOut: PbLegOut[]; timing: Uint8Array; exclusiveFiller: Uint8Array;
  minFillAnchor: Uint8Array; exclusivityOverrideBps: Uint8Array; curve: PbCurvePoint[];
  gasBumpBps: Uint8Array; gasPriceRef: Uint8Array; items: PbItem[]; validators: PbValidator[];
  invariants: PbValidator[]; fillModule: Uint8Array; fillTotal: Uint8Array;
}
interface PbTokenPermit { spender: Uint8Array; token: Uint8Array; amount: Uint8Array; expiration: number }
interface PbTakerPermit { spender: Uint8Array; ref: Uint8Array; amount: Uint8Array; expiration: number }
interface PbPermitBatch { tokens: PbTokenPermit[]; takers: PbTakerPermit[]; nonce: Uint8Array; deadline: Uint8Array }
interface PbOrderAnnounce { order: PbOrder; sig: Uint8Array; permitBatch?: PbPermitBatch | null; sigless: boolean }
interface PbOrderSoftCancel { orderHash: Uint8Array; makerSig: Uint8Array }
interface PbFillNotice { orderHash: Uint8Array; filler: Uint8Array }

// ──────────────────── Order ⇄ wire ────────────────────

/** Map a viem `Order` to its protobuf plain-object form. */
export function orderToProto(o: Order): PbOrder {
  return {
    maker: addrToBytes(o.maker),
    side: o.side,
    nonce: u256ToBytes(o.nonce),
    deadline: u256ToBytes(o.deadline),
    legsIn: o.legsIn.map((l): PbLegIn => ({ token: addrToBytes(l.token), start: u256ToBytes(l.start), end: u256ToBytes(l.end) })),
    legsOut: o.legsOut.map((l): PbLegOut => ({ token: addrToBytes(l.token), start: u256ToBytes(l.start), end: u256ToBytes(l.end), recipient: addrToBytes(l.recipient) })),
    timing: u256ToBytes(o.timing),
    exclusiveFiller: addrToBytes(o.exclusiveFiller),
    minFillAnchor: u256ToBytes(o.minFillAnchor),
    exclusivityOverrideBps: u256ToBytes(o.exclusivityOverrideBps),
    curve: o.curve.map((c): PbCurvePoint => ({ timeDelta: c.timeDelta, bumpBps: c.bumpBps })),
    gasBumpBps: u256ToBytes(o.gasBumpBps),
    gasPriceRef: u256ToBytes(o.gasPriceRef),
    items: o.items.map((i): PbItem => ({ op: i.op, module: addrToBytes(i.module), amount: u256ToBytes(i.amount), recipient: addrToBytes(i.recipient), data: hexToU8(i.data) })),
    validators: o.validators.map((v): PbValidator => ({ target: addrToBytes(v.target), data: hexToU8(v.data) })),
    invariants: o.invariants.map((v): PbValidator => ({ target: addrToBytes(v.target), data: hexToU8(v.data) })),
    fillModule: addrToBytes(o.fillModule),
    fillTotal: u256ToBytes(o.fillTotal),
  };
}

/** Rebuild the exact viem `Order` from its protobuf form (round-trips `hashOrderStruct`). */
export function protoToOrder(p: PbOrder): Order {
  return {
    maker: bytesToAddr(p.maker),
    side: p.side as OrderSide,
    nonce: bytesToU256(p.nonce),
    deadline: bytesToU256(p.deadline),
    legsIn: (p.legsIn ?? []).map((l): LegIn => ({ token: bytesToAddr(l.token), start: bytesToU256(l.start), end: bytesToU256(l.end) })),
    legsOut: (p.legsOut ?? []).map((l): LegOut => ({ token: bytesToAddr(l.token), start: bytesToU256(l.start), end: bytesToU256(l.end), recipient: bytesToAddr(l.recipient) })),
    timing: bytesToU256(p.timing),
    exclusiveFiller: bytesToAddr(p.exclusiveFiller),
    minFillAnchor: bytesToU256(p.minFillAnchor),
    exclusivityOverrideBps: bytesToU256(p.exclusivityOverrideBps),
    curve: (p.curve ?? []).map((c): CurvePoint => ({ timeDelta: toNum(c.timeDelta), bumpBps: toNum(c.bumpBps) })),
    gasBumpBps: bytesToU256(p.gasBumpBps),
    gasPriceRef: bytesToU256(p.gasPriceRef),
    items: (p.items ?? []).map((i): Item => ({ op: toNum(i.op) as ItemOp, module: bytesToAddr(i.module), amount: bytesToU256(i.amount), recipient: bytesToAddr(i.recipient), data: u8ToHex(i.data) })),
    validators: (p.validators ?? []).map((v): Validator => ({ target: bytesToAddr(v.target), data: u8ToHex(v.data) })),
    invariants: (p.invariants ?? []).map((v): Validator => ({ target: bytesToAddr(v.target), data: u8ToHex(v.data) })),
    fillModule: bytesToAddr(p.fillModule),
    fillTotal: bytesToU256(p.fillTotal),
  };
}

function permitBatchToProto(b: PermitBatch): PbPermitBatch {
  return {
    tokens: b.tokens.map((t): PbTokenPermit => ({ spender: addrToBytes(t.spender), token: addrToBytes(t.token), amount: u256ToBytes(t.amount), expiration: t.expiration })),
    takers: b.takers.map((t): PbTakerPermit => ({ spender: addrToBytes(t.spender), ref: hexToU8(t.ref), amount: u256ToBytes(t.amount), expiration: t.expiration })),
    nonce: u256ToBytes(b.nonce),
    deadline: u256ToBytes(b.deadline),
  };
}
function protoToPermitBatch(p: PbPermitBatch): PermitBatch {
  return {
    tokens: (p.tokens ?? []).map((t): TokenPermit => ({ spender: bytesToAddr(t.spender), token: bytesToAddr(t.token), amount: bytesToU256(t.amount), expiration: toNum(t.expiration) })),
    takers: (p.takers ?? []).map((t): TakerPermit => ({ spender: bytesToAddr(t.spender), ref: u8ToHex(t.ref) as Hex, amount: bytesToU256(t.amount), expiration: toNum(t.expiration) })),
    nonce: bytesToU256(p.nonce),
    deadline: bytesToU256(p.deadline),
  };
}

function announceToProto(a: OrderAnnounce): PbOrderAnnounce {
  return {
    order: orderToProto(a.order),
    sig: hexToU8(a.sig),
    permitBatch: a.permitBatch ? permitBatchToProto(a.permitBatch) : undefined,
    sigless: a.sigless ?? false,
  };
}
function protoToAnnounce(p: PbOrderAnnounce): OrderAnnounce {
  if (!p.order) throw new Error("OrderAnnounce missing order");
  return {
    order: protoToOrder(p.order),
    sig: u8ToHex(p.sig),
    ...(p.permitBatch ? { permitBatch: protoToPermitBatch(p.permitBatch) } : {}),
    sigless: Boolean(p.sigless),
  };
}

// ──────────────────── message encode / decode ────────────────────

export function encodeOrderAnnounce(a: OrderAnnounce): Uint8Array {
  return OrderAnnounceT.encode(announceToProto(a) as object).finish();
}
export function decodeOrderAnnounce(b: Uint8Array): OrderAnnounce {
  return protoToAnnounce(OrderAnnounceT.decode(b) as unknown as PbOrderAnnounce);
}

export function encodeOrderSoftCancel(c: OrderSoftCancel): Uint8Array {
  const p: PbOrderSoftCancel = { orderHash: hexToU8(c.orderHash), makerSig: hexToU8(c.makerSig) };
  return OrderSoftCancelT.encode(p as object).finish();
}
export function decodeOrderSoftCancel(b: Uint8Array): OrderSoftCancel {
  const p = OrderSoftCancelT.decode(b) as unknown as PbOrderSoftCancel;
  return { orderHash: u8ToHex(p.orderHash), makerSig: u8ToHex(p.makerSig) };
}

export function encodeFillNotice(n: FillNotice): Uint8Array {
  const p: PbFillNotice = { orderHash: hexToU8(n.orderHash), filler: addrToBytes(n.filler) };
  return FillNoticeT.encode(p as object).finish();
}
export function decodeFillNotice(b: Uint8Array): FillNotice {
  const p = FillNoticeT.decode(b) as unknown as PbFillNotice;
  return { orderHash: u8ToHex(p.orderHash), filler: bytesToAddr(p.filler) };
}

export function encodeOrderList(items: readonly OrderAnnounce[]): Uint8Array {
  return OrderListT.encode({ orders: items.map(announceToProto) } as object).finish();
}
export function decodeOrderList(b: Uint8Array): OrderAnnounce[] {
  const p = OrderListT.decode(b) as unknown as { orders?: PbOrderAnnounce[] };
  return (p.orders ?? []).map(protoToAnnounce);
}

/** Backend→client WebSocket stream envelope. */
export type StreamMessage =
  | { kind: StreamKind.SNAPSHOT; orders: OrderAnnounce[] }
  | { kind: StreamKind.ADD; order: OrderAnnounce }
  | { kind: StreamKind.CANCEL; cancel: OrderSoftCancel };

export function encodeStreamMessage(m: StreamMessage): Uint8Array {
  const obj =
    m.kind === StreamKind.SNAPSHOT ? { kind: m.kind, orders: m.orders.map(announceToProto) }
    : m.kind === StreamKind.ADD ? { kind: m.kind, order: announceToProto(m.order) }
    : { kind: m.kind, cancel: { orderHash: hexToU8(m.cancel.orderHash), makerSig: hexToU8(m.cancel.makerSig) } };
  return StreamMessageT.encode(obj as object).finish();
}
export function decodeStreamMessage(b: Uint8Array): StreamMessage {
  const p = StreamMessageT.decode(b) as unknown as {
    kind: number; orders?: PbOrderAnnounce[]; order?: PbOrderAnnounce | null;
    cancel?: PbOrderSoftCancel | null;
  };
  const kind = toNum(p.kind) as StreamKind;
  if (kind === StreamKind.ADD) {
    if (!p.order) throw new Error("StreamMessage ADD missing order");
    return { kind, order: protoToAnnounce(p.order) };
  }
  if (kind === StreamKind.CANCEL) {
    if (!p.cancel) throw new Error("StreamMessage CANCEL missing cancel");
    return { kind, cancel: { orderHash: u8ToHex(p.cancel.orderHash), makerSig: u8ToHex(p.cancel.makerSig) } };
  }
  return { kind: StreamKind.SNAPSHOT, orders: (p.orders ?? []).map(protoToAnnounce) };
}
