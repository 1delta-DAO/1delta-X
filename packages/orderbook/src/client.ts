import type { Order } from "@1delta-x/sdk";
import type { Hex } from "viem";

import type { OrderbookConfig } from "./config";
import type { OrderAnnounce, OrderSoftCancel } from "./messages";
import {
  decodeOrderAnnounce,
  decodeOrderList,
  decodeOrderSoftCancel,
  decodeStreamMessage,
  encodeOrderAnnounce,
  encodeOrderSoftCancel,
} from "./proto/codec";
import { StreamKind } from "./proto/schema";
import { cancelTopic, orderTopic } from "./topics";
import type { MessageHandler, Transport, Unsubscribe } from "./transport";

/** Minimal EIP-191 signer surface — a viem `LocalAccount`/`WalletClient` satisfies it. */
export interface MessageSigner {
  signMessage(args: { message: { raw: Hex } }): Promise<Hex>;
}

/** Sign a soft cancel: EIP-191 over the raw 32-byte `orderHash`. */
export async function signSoftCancel(signer: MessageSigner, orderHash: Hex): Promise<OrderSoftCancel> {
  return { orderHash, makerSig: await signer.signMessage({ message: { raw: orderHash } }) };
}

// ──────────────────── HTTP transport (client ↔ demo backend) ────────────────────

function toU8(data: unknown): Uint8Array | undefined {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  return undefined;
}

/** Just enough of the WebSocket surface for the stream, so `ws` or the global both fit. */
interface WSLike {
  binaryType: string;
  addEventListener(type: string, cb: (ev: { data: unknown }) => void): void;
  close(): void;
}
type WSFactory = (url: string) => WSLike;

export interface HttpTransportOptions {
  /** e.g. `http://localhost:8080`. */
  baseUrl: string;
  config: Pick<OrderbookConfig, "chainId" | "settlement">;
  /** WebSocket stream URL; defaults to `baseUrl` with http→ws + `/stream`. */
  streamUrl?: string;
  /** Inject a WebSocket ctor (Node <18 or a custom `ws`); defaults to global. */
  webSocket?: WSFactory;
  /** Inject fetch; defaults to global. */
  fetch?: typeof fetch;
}

/**
 * A {@link Transport} backed by the centralized demo backend: `publish` → REST
 * POST, `subscribe` → the WebSocket stream, `queryHistory` → REST GET. A filler
 * can therefore run a {@link Book} over `new HttpTransport(...)` today and over a
 * `WakuTransport` tomorrow with no other change — that is the whole point of the
 * seam.
 */
export class HttpTransport implements Transport {
  private readonly baseUrl: string;
  private readonly streamUrl: string;
  private readonly orders: string;
  private readonly cancels: string;
  private readonly wsFactory: WSFactory;
  private readonly doFetch: typeof fetch;
  private ws: WSLike | undefined;
  private readonly handlers = new Map<string, Set<MessageHandler>>();

  constructor(opts: HttpTransportOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, "");
    this.streamUrl = opts.streamUrl ?? `${this.baseUrl.replace(/^http/, "ws")}/stream`;
    this.orders = orderTopic(opts.config.chainId, opts.config.settlement);
    this.cancels = cancelTopic(opts.config.chainId, opts.config.settlement);
    const g = globalThis as { WebSocket?: new (url: string) => WSLike; fetch?: typeof fetch };
    const WS = opts.webSocket ?? (g.WebSocket ? (url: string) => new g.WebSocket!(url) : undefined);
    if (!WS) throw new Error("no WebSocket available — pass options.webSocket");
    this.wsFactory = WS;
    const f = opts.fetch ?? g.fetch;
    if (!f) throw new Error("no fetch available — pass options.fetch");
    this.doFetch = f;
  }

  async publish(topic: string, payload: Uint8Array): Promise<void> {
    const path = topic === this.orders ? "/orders" : topic === this.cancels ? "/cancels" : undefined;
    if (!path) throw new Error(`HttpTransport: unsupported topic ${topic}`);
    const res = await this.doFetch(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: { "content-type": "application/x-protobuf" },
      body: payload as BodyInit,
    });
    if (!res.ok) throw new Error(`publish failed (${res.status}): ${await res.text().catch(() => res.statusText)}`);
  }

  async subscribe(topic: string, onMessage: MessageHandler): Promise<Unsubscribe> {
    let set = this.handlers.get(topic);
    if (!set) {
      set = new Set();
      this.handlers.set(topic, set);
    }
    set.add(onMessage);
    this.ensureSocket();
    return () => {
      this.handlers.get(topic)?.delete(onMessage);
    };
  }

  async queryHistory(topic: string): Promise<Uint8Array[]> {
    if (topic !== this.orders) return [];
    const res = await this.doFetch(`${this.baseUrl}/orders`, { headers: { accept: "application/x-protobuf" } });
    if (!res.ok) return [];
    const list = decodeOrderList(new Uint8Array(await res.arrayBuffer()));
    return list.map(encodeOrderAnnounce);
  }

  close(): void {
    this.ws?.close();
    this.ws = undefined;
  }

  private ensureSocket(): void {
    if (this.ws) return;
    const ws = this.wsFactory(this.streamUrl);
    try {
      ws.binaryType = "arraybuffer";
    } catch {
      /* some impls fix binaryType */
    }
    ws.addEventListener("message", (ev) => {
      const u8 = toU8(ev.data);
      if (u8) this.dispatch(u8);
    });
    this.ws = ws;
  }

  private dispatch(bytes: Uint8Array): void {
    let msg;
    try {
      msg = decodeStreamMessage(bytes);
    } catch {
      return;
    }
    if (msg.kind === StreamKind.SNAPSHOT) {
      for (const a of msg.orders) this.fanout(this.orders, encodeOrderAnnounce(a));
    } else if (msg.kind === StreamKind.ADD) {
      this.fanout(this.orders, encodeOrderAnnounce(msg.order));
    } else {
      this.fanout(this.cancels, encodeOrderSoftCancel(msg.cancel));
    }
  }

  private fanout(topic: string, payload: Uint8Array): void {
    const set = this.handlers.get(topic);
    if (!set) return;
    for (const h of [...set]) {
      try {
        h(payload);
      } catch {
        /* subscriber error is its own problem */
      }
    }
  }
}

// ──────────────────── ergonomic client ────────────────────

export interface PublishOrderOpts {
  permitBatch?: OrderAnnounce["permitBatch"];
  sigless?: boolean;
}

/**
 * Thin, ergonomic wrapper over any {@link Transport} + a deployment config. This
 * is the SDK surface a maker dApp or filler instantiates; swapping
 * `new HttpTransport(...)` for a Waku transport at construction is the only
 * change needed to go P2P.
 */
export class OrderbookClient {
  constructor(
    private readonly transport: Transport,
    private readonly config: Pick<OrderbookConfig, "chainId" | "settlement">,
  ) {}

  private get orders(): string {
    return orderTopic(this.config.chainId, this.config.settlement);
  }
  private get cancels(): string {
    return cancelTopic(this.config.chainId, this.config.settlement);
  }

  async publishOrder(order: Order, sig: Hex, opts?: PublishOrderOpts): Promise<void> {
    await this.publishAnnounce({ order, sig, ...opts });
  }

  async publishAnnounce(announce: OrderAnnounce): Promise<void> {
    await this.transport.publish(this.orders, encodeOrderAnnounce(announce));
  }

  async cancelOrder(cancel: OrderSoftCancel): Promise<void> {
    await this.transport.publish(this.cancels, encodeOrderSoftCancel(cancel));
  }

  async subscribeOrders(onOrder: (a: OrderAnnounce) => void): Promise<Unsubscribe> {
    return this.transport.subscribe(this.orders, (b) => {
      try {
        onOrder(decodeOrderAnnounce(b));
      } catch {
        /* skip undecodable frame */
      }
    });
  }

  async subscribeCancels(onCancel: (c: OrderSoftCancel) => void): Promise<Unsubscribe> {
    return this.transport.subscribe(this.cancels, (b) => {
      try {
        onCancel(decodeOrderSoftCancel(b));
      } catch {
        /* skip undecodable frame */
      }
    });
  }

  /** One-shot backfill via `transport.queryHistory` (the current book). */
  async fetchBook(): Promise<OrderAnnounce[]> {
    if (!this.transport.queryHistory) return [];
    const history = await this.transport.queryHistory(this.orders);
    return history.map((b) => decodeOrderAnnounce(b));
  }
}
