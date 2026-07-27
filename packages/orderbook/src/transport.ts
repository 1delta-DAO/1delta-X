/**
 * The single seam that makes "centralized demo now, Waku later" real. A
 * `Transport` moves opaque protobuf bytes on named content topics; it does NOT
 * match, sequence, or hold "the" book. `Book` and the verification pipeline sit
 * entirely above it, so swapping this interface's implementation — in-memory bus
 * → HTTP client → Waku Relay/Store — leaves everything else untouched.
 */
export type MessageHandler = (payload: Uint8Array) => void;
export type Unsubscribe = () => void;

export interface Transport {
  /** Broadcast `payload` on `topic`. */
  publish(topic: string, payload: Uint8Array): Promise<void>;
  /** Subscribe to live messages on `topic`. Returns an unsubscribe handle. */
  subscribe(topic: string, onMessage: MessageHandler): Promise<Unsubscribe>;
  /** Backfill recent messages on `topic` (Waku Store analogue). Optional. */
  queryHistory?(topic: string, opts?: { limit?: number }): Promise<Uint8Array[]>;
}

/**
 * In-process pub/sub with a bounded per-topic ring buffer. Backs the demo
 * backend's internal bus (it plays the "infra node" Relay+Store role) and every
 * unit/integration test — no network, no Waku. The Waku transport is a drop-in
 * replacement implementing the same three methods.
 */
export class InMemoryTransport implements Transport {
  private readonly subs = new Map<string, Set<MessageHandler>>();
  private readonly history = new Map<string, Uint8Array[]>();
  private readonly historyLimit: number;

  constructor(opts?: { historyLimit?: number }) {
    this.historyLimit = opts?.historyLimit ?? 1000;
  }

  async publish(topic: string, payload: Uint8Array): Promise<void> {
    const ring = this.history.get(topic) ?? [];
    ring.push(payload);
    if (ring.length > this.historyLimit) ring.shift();
    this.history.set(topic, ring);

    const handlers = this.subs.get(topic);
    if (handlers) {
      for (const h of [...handlers]) {
        // One misbehaving subscriber must not stall the fan-out to the others.
        try {
          h(payload);
        } catch {
          /* subscriber error is its own problem */
        }
      }
    }
  }

  async subscribe(topic: string, onMessage: MessageHandler): Promise<Unsubscribe> {
    let set = this.subs.get(topic);
    if (!set) {
      set = new Set();
      this.subs.set(topic, set);
    }
    set.add(onMessage);
    return () => {
      this.subs.get(topic)?.delete(onMessage);
    };
  }

  async queryHistory(topic: string, opts?: { limit?: number }): Promise<Uint8Array[]> {
    const ring = this.history.get(topic) ?? [];
    const limit = opts?.limit;
    return limit != null && limit < ring.length ? ring.slice(ring.length - limit) : [...ring];
  }
}
