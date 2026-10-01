import { buildSoftCancel, signSoftCancel as signSoftCancelTyped, type Deployment, type Order, type SoftCancel, type TypedDataSigner } from "@1delta-x/sdk";
import type { Hex } from "viem";

import type { CancelVerifier } from "./cancels";
import type { OrderbookConfig } from "./config";
import type { OrderAnnounce, OrderReplace, SignedSoftCancel } from "./messages";
import {
  decodeOrderAnnounce,
  decodeOrderList,
  decodeOrderReplace,
  decodeSoftCancel,
  decodeStreamMessage,
  encodeOrderAnnounce,
  encodeOrderReplace,
  encodeSoftCancel,
} from "./proto/codec";
import { StreamKind } from "./proto/schema";
import { cancelTopic, orderTopic, replaceTopic } from "./topics";
import type { MessageHandler, Transport, Unsubscribe } from "./transport";

/**
 * Build + sign a soft cancel over one or more order hashes.
 *
 * EIP-712 in the SETTLEMENT domain, not `personal_sign` over a bare hash: the
 * domain pins the message to one chain + settlement (so a cancel cannot be
 * replayed across deployments), the wallet renders named fields instead of an
 * opaque blob, and the SAME signer set the settlement accepts for an order
 * verifies it — EOA, EIP-1271 contract maker, or a nominated delegate.
 */
export async function signSoftCancel(
  signer: TypedDataSigner,
  maker: Hex,
  orderHashes: readonly Hex[],
  d: Deployment,
  opts?: { now?: bigint; ttlSeconds?: bigint },
): Promise<SignedSoftCancel> {
  const cancel: SoftCancel = buildSoftCancel(maker as `0x${string}`, orderHashes, opts);
  return { cancel, sig: await signSoftCancelTyped(signer, cancel, d) };
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
  /** Upper bound on pages one `queryHistory` walks. Default 200 (100k orders). */
  maxHistoryPages?: number;
}

/** Page size `queryHistory` asks for — the server's maximum. */
const HISTORY_PAGE = 500;

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
  private readonly replaces: string;
  private readonly wsFactory: WSFactory;
  private readonly doFetch: typeof fetch;
  private readonly maxHistoryPages: number;
  private ws: WSLike | undefined;
  private readonly handlers = new Map<string, Set<MessageHandler>>();

  constructor(opts: HttpTransportOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, "");
    this.streamUrl = opts.streamUrl ?? `${this.baseUrl.replace(/^http/, "ws")}/stream`;
    this.orders = orderTopic(opts.config.chainId, opts.config.settlement);
    this.cancels = cancelTopic(opts.config.chainId, opts.config.settlement);
    this.replaces = replaceTopic(opts.config.chainId, opts.config.settlement);
    const g = globalThis as { WebSocket?: new (url: string) => WSLike; fetch?: typeof fetch };
    const WS = opts.webSocket ?? (g.WebSocket ? (url: string) => new g.WebSocket!(url) : undefined);
    if (!WS) throw new Error("no WebSocket available — pass options.webSocket");
    this.wsFactory = WS;
    const f = opts.fetch ?? g.fetch;
    if (!f) throw new Error("no fetch available — pass options.fetch");
    this.doFetch = f;
    this.maxHistoryPages = Math.max(1, opts.maxHistoryPages ?? 200);
  }

  async publish(topic: string, payload: Uint8Array): Promise<void> {
    const path =
      topic === this.orders ? "/orders" : topic === this.cancels ? "/cancels" : topic === this.replaces ? "/replaces" : undefined;
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

  /**
   * The whole book, PAGED. One unparameterised GET used to return the server's
   * default page (100) and stop, so a backfilling book silently started with a
   * fraction of the orders and never learned it. Pages follow the server's
   * `x-next-cursor` header until it stops, `opts.limit` is reached, or
   * {@link HttpTransportOptions.maxHistoryPages} runs out.
   */
  async queryHistory(topic: string, opts?: { limit?: number }): Promise<Uint8Array[]> {
    if (topic !== this.orders) return [];
    const out: Uint8Array[] = [];
    let cursor: string | undefined;
    for (let page = 0; page < this.maxHistoryPages; page++) {
      const want = opts?.limit !== undefined ? Math.min(HISTORY_PAGE, opts.limit - out.length) : HISTORY_PAGE;
      if (want <= 0) break;
      const qs = `limit=${want}${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ""}`;
      const res = await this.doFetch(`${this.baseUrl}/orders?${qs}`, { headers: { accept: "application/x-protobuf" } });
      if (!res.ok) break;
      const list = decodeOrderList(new Uint8Array(await res.arrayBuffer()));
      for (const a of list) out.push(encodeOrderAnnounce(a));
      cursor = res.headers?.get?.("x-next-cursor") ?? undefined;
      if (!cursor || list.length === 0) break;
    }
    return out;
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
    } else if (msg.kind === StreamKind.CANCEL) {
      this.fanout(this.cancels, encodeSoftCancel(msg.cancel));
    } else {
      // A replace goes out WHOLE, on the replace topic only. It used to be split
      // onto the order and cancel topics too, and a `Book` (which subscribes all
      // three) then applied the cancel half on its own — evicting the predecessor
      // even when the replacement failed to verify on this node, the exact
      // non-atomicity the message exists to prevent. Consumers that want the
      // halves get them from {OrderbookClient.subscribeOrders} / `subscribeCancels`.
      this.fanout(this.replaces, encodeOrderReplace(msg.replace));
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

/** What {@link OrderbookClient.subscribeOrders} needs to authenticate an announce — a {@link Verifier} fits. */
export interface AnnounceVerifier {
  verifyAnnounce(a: OrderAnnounce): Promise<{ ok: boolean }>;
}

/** What {@link OrderbookClient.subscribeCancels} needs to authenticate a cancel — a {@link CancelVerifier} fits. */
export type SoftCancelVerifier = Pick<CancelVerifier, "verify">;

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
  private get replaces(): string {
    return replaceTopic(this.config.chainId, this.config.settlement);
  }

  async publishOrder(order: Order, sig: Hex, opts?: PublishOrderOpts): Promise<void> {
    await this.publishAnnounce({ order, sig, ...opts });
  }

  async publishAnnounce(announce: OrderAnnounce): Promise<void> {
    await this.transport.publish(this.orders, encodeOrderAnnounce(announce));
  }

  async cancelOrder(cancel: SignedSoftCancel): Promise<void> {
    await this.transport.publish(this.cancels, encodeSoftCancel(cancel));
  }

  /**
   * Publish a cancel-and-replace on the REPLACE topic. One message carries both
   * the retraction and the replacement, so a node never sees the cancel alone and
   * drops the maker's quote instead of re-pricing it. (It used to ride the order
   * topic, which no book decoded as a replace — F29 P6.)
   */
  async replaceOrder(replace: OrderReplace): Promise<void> {
    await this.transport.publish(this.replaces, encodeOrderReplace(replace));
  }

  async subscribeReplaces(onReplace: (r: OrderReplace) => void): Promise<Unsubscribe> {
    return this.transport.subscribe(this.replaces, (b) => {
      try {
        onReplace(decodeOrderReplace(b));
      } catch {
        /* not a replace frame */
      }
    });
  }

  /**
   * New orders — including the replacement half of every cancel-and-replace.
   *
   * ⚠ UNVERIFIED BY DEFAULT (audit 2026-09-30 G-TS_FILLER-10). Without
   * `opts.verifier` every decodable frame on the topic is handed over as-is: a
   * relay or any peer can publish an announce with a forged or garbage signature,
   * an order the chain will refuse, or a `permitBatch` nobody signed. Treat the
   * raw stream as a hint. Pass a {@link Verifier} (Layer 1 + Layer 2) to receive
   * only announces that verify — or run a {@link Book}, which does that and more.
   */
  async subscribeOrders(onOrder: (a: OrderAnnounce) => void, opts?: { verifier?: AnnounceVerifier }): Promise<Unsubscribe> {
    const verifier = opts?.verifier;
    const deliver = (a: OrderAnnounce): void => {
      if (!verifier) {
        onOrder(a);
        return;
      }
      void verifier.verifyAnnounce(a).then(
        (r) => {
          if (r.ok) onOrder(a);
        },
        () => undefined, // unverifiable right now is not "verified"
      );
    };
    const offOrders = await this.transport.subscribe(this.orders, (b) => {
      let a: OrderAnnounce;
      try {
        a = decodeOrderAnnounce(b);
      } catch {
        return; /* skip undecodable frame */
      }
      deliver(a);
    });
    const offReplaces = await this.subscribeReplaces((r) => deliver(r.announce));
    return () => {
      offOrders();
      offReplaces();
    };
  }

  /**
   * Retractions — including the cancel half of every cancel-and-replace.
   *
   * ⚠ UNVERIFIED BY DEFAULT (audit 2026-09-30 G-TS_FILLER-10). Without
   * `opts.cancelVerifier` anyone can publish a "cancel" naming any maker and any
   * order hash, and it is handed over as-is. With it, only cancels whose signature
   * verifies for `cancel.maker` are delivered — and even then a verified cancel
   * proves only WHO signed it: retract a hash only when the order you hold under it
   * names that maker (see {@link evictableHashes}; {@link Book} does both).
   */
  async subscribeCancels(
    onCancel: (c: SignedSoftCancel) => void,
    opts?: { cancelVerifier?: SoftCancelVerifier },
  ): Promise<Unsubscribe> {
    const verifier = opts?.cancelVerifier;
    const deliver = (c: SignedSoftCancel): void => {
      if (!verifier) {
        onCancel(c);
        return;
      }
      void verifier.verify(c).then(
        (v) => {
          if (v.ok && v.maker?.toLowerCase() === c.cancel.maker.toLowerCase()) onCancel(c);
        },
        () => undefined,
      );
    };
    const offCancels = await this.transport.subscribe(this.cancels, (b) => {
      let c: SignedSoftCancel;
      try {
        c = decodeSoftCancel(b);
      } catch {
        return; /* skip undecodable frame */
      }
      deliver(c);
    });
    const offReplaces = await this.subscribeReplaces((r) => deliver(r.cancel));
    return () => {
      offCancels();
      offReplaces();
    };
  }

  /** One-shot backfill via `transport.queryHistory` (the current book). */
  async fetchBook(): Promise<OrderAnnounce[]> {
    if (!this.transport.queryHistory) return [];
    const history = await this.transport.queryHistory(this.orders);
    return history.map((b) => decodeOrderAnnounce(b));
  }
}
