/**
 * The state of a transaction the app sends ITSELF — wrap, approve, Permit3 grant,
 * unwrap, on-chain cancel — as one visible line:
 *
 *   Confirm in wallet… → Submitted · 0xab…cd ↗ → Confirming… (sent after block N)
 *     → Confirmed ✓   |   Failed: <reason>   |   Rejected in wallet
 *
 * with "step k of n" when a funding plan sends several. Pure reducer + a runner
 * over injected I/O, so every transition is pinned by a test.
 */
import type { Hex } from "viem";

export interface TxMeta {
  /** "Approve USDRIF to Permit3", "Wrap 0.01 RBTC". */
  label: string;
  /** 1-based position in a multi-transaction flow, and its length. */
  step: number;
  of: number;
}

export type TxState =
  | { kind: "idle" }
  | ({ kind: "wallet" } & TxMeta)
  | ({ kind: "submitted"; hash: Hex } & TxMeta)
  | ({ kind: "confirming"; hash: Hex; sinceBlock: bigint | null } & TxMeta)
  | ({ kind: "confirmed"; hash: Hex; block: bigint | null } & TxMeta)
  | ({ kind: "failed"; reason: string; hash: Hex | null } & TxMeta)
  | ({ kind: "rejected" } & TxMeta);

export type TxEvent =
  | ({ type: "start" } & TxMeta)
  | { type: "sent"; hash: Hex }
  | { type: "confirming"; sinceBlock: bigint | null }
  | { type: "confirmed"; block: bigint | null }
  | { type: "error"; error: unknown }
  | { type: "reset" };

export const IDLE: TxState = { kind: "idle" };

/** A wallet's "user rejected the request" (EIP-1193 4001, or the usual wording). */
export function isRejection(e: unknown): boolean {
  const seen = new Set<unknown>();
  let cur: unknown = e;
  while (cur && typeof cur === "object" && !seen.has(cur)) {
    seen.add(cur);
    const c = cur as { code?: unknown; name?: unknown; message?: unknown; shortMessage?: unknown; cause?: unknown };
    if (c.code === 4001 || c.name === "UserRejectedRequestError") return true;
    const msg = `${typeof c.shortMessage === "string" ? c.shortMessage : ""} ${typeof c.message === "string" ? c.message : ""}`;
    if (/user (rejected|denied|cancel)|rejected the request|request rejected|denied transaction/i.test(msg)) return true;
    cur = c.cause;
  }
  return false;
}

/** First line of an error — wallets send multi-paragraph dumps. */
export function errorReason(e: unknown): string {
  if (typeof e === "object" && e) {
    const c = e as { shortMessage?: unknown; message?: unknown };
    const m = typeof c.shortMessage === "string" && c.shortMessage ? c.shortMessage : typeof c.message === "string" ? c.message : "";
    if (m) return m.split("\n")[0]!.slice(0, 160);
  }
  return String(e).split("\n")[0]!.slice(0, 160);
}

function metaOf(s: TxState): TxMeta | null {
  return s.kind === "idle" ? null : { label: s.label, step: s.step, of: s.of };
}

export function txReducer(s: TxState, e: TxEvent): TxState {
  if (e.type === "reset") return IDLE;
  if (e.type === "start") return { kind: "wallet", label: e.label, step: e.step, of: e.of };
  const m = metaOf(s);
  if (!m) return s; // an event with no transaction in flight: ignore
  switch (e.type) {
    case "sent":
      return { kind: "submitted", hash: e.hash, ...m };
    case "confirming":
      return s.kind === "submitted" ? { kind: "confirming", hash: s.hash, sinceBlock: e.sinceBlock, ...m } : s;
    case "confirmed":
      return s.kind === "submitted" || s.kind === "confirming" ? { kind: "confirmed", hash: s.hash, block: e.block, ...m } : s;
    case "error": {
      const hash = s.kind === "submitted" || s.kind === "confirming" ? s.hash : null;
      // Only a prompt the wallet never sent can be a rejection.
      if (hash === null && isRejection(e.error)) return { kind: "rejected", ...m };
      return { kind: "failed", reason: errorReason(e.error), hash, ...m };
    }
  }
}

/** Whether a flow is waiting on the wallet or the chain (buttons stay disabled). */
export function inFlight(s: TxState): boolean {
  return s.kind === "wallet" || s.kind === "submitted" || s.kind === "confirming";
}

export interface TxIo {
  send: () => Promise<Hex>;
  wait: (hash: Hex) => Promise<{ status: "success" | "reverted"; blockNumber?: bigint }>;
  blockNumber?: () => Promise<bigint>;
}

/**
 * Send one transaction through the states. Resolves with its hash once mined
 * successfully; rejects (after dispatching the failure) otherwise.
 */
export async function runTx(dispatch: (e: TxEvent) => void, meta: TxMeta, io: TxIo): Promise<Hex> {
  dispatch({ type: "start", ...meta });
  let hash: Hex;
  try {
    hash = await io.send();
  } catch (error) {
    dispatch({ type: "error", error });
    throw error;
  }
  dispatch({ type: "sent", hash });
  let since: bigint | null = null;
  try {
    since = io.blockNumber ? await io.blockNumber() : null;
  } catch {
    since = null;
  }
  dispatch({ type: "confirming", sinceBlock: since });
  let receipt: Awaited<ReturnType<TxIo["wait"]>>;
  try {
    receipt = await io.wait(hash);
  } catch (error) {
    dispatch({ type: "error", error });
    throw error;
  }
  if (receipt.status !== "success") {
    const error = new Error("transaction reverted on-chain");
    dispatch({ type: "error", error });
    throw error;
  }
  dispatch({ type: "confirmed", block: receipt.blockNumber ?? null });
  return hash;
}

/** Block explorer link for a transaction. Rootstock → Blockscout. */
export function explorerTx(chainId: number, hash: string): string | null {
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) return null;
  if (chainId === 30) return `https://rootstock.blockscout.com/tx/${hash}`;
  if (chainId === 31) return `https://rootstock-testnet.blockscout.com/tx/${hash}`;
  if (chainId === 1) return `https://etherscan.io/tx/${hash}`;
  if (chainId === 56) return `https://bscscan.com/tx/${hash}`;
  return null;
}

export interface TxLine {
  /** "Step 2 of 3" or "". */
  step: string;
  text: string;
  tone: "busy" | "confirmed" | "failed" | "rejected" | "idle";
  /** The transaction to link, when one exists. */
  hash: Hex | null;
  /** A failure / rejection can be retried. */
  retry: boolean;
}

export function txLine(s: TxState): TxLine {
  if (s.kind === "idle") return { step: "", text: "", tone: "idle", hash: null, retry: false };
  const step = s.of > 1 ? `Step ${s.step} of ${s.of}` : "";
  switch (s.kind) {
    case "wallet":
      return { step, text: `${s.label} — confirm in your wallet…`, tone: "busy", hash: null, retry: false };
    case "submitted":
      return { step, text: `${s.label} — submitted`, tone: "busy", hash: s.hash, retry: false };
    case "confirming":
      return {
        step,
        text: `${s.label} — submitted · confirming…${s.sinceBlock !== null ? ` (sent after block ${s.sinceBlock.toString()})` : " (waiting for a block)"}`,
        tone: "busy",
        hash: s.hash,
        retry: false,
      };
    case "confirmed":
      return {
        step,
        text: `${s.label} — confirmed ✓${s.block !== null ? ` in block ${s.block.toString()}` : ""}`,
        tone: "confirmed",
        hash: s.hash,
        retry: false,
      };
    case "failed":
      return { step, text: `${s.label} — failed: ${s.reason}`, tone: "failed", hash: s.hash, retry: true };
    case "rejected":
      return { step, text: `${s.label} — rejected in wallet`, tone: "rejected", hash: null, retry: true };
  }
}
