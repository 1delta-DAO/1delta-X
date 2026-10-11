import { shortHex } from "../lib/format";
import type { PhaseLine } from "../lib/orderLifecycle";
import { explorerTx, txLine, type TxState } from "../lib/txFlow";

/** A transaction hash as a short explorer link (plain text where the chain has no explorer). */
export function TxLink({ chainId, hash }: { chainId: number; hash: string }) {
  const href = explorerTx(chainId, hash);
  const text = shortHex(hash, 8, 6);
  return href ? (
    <a href={href} target="_blank" rel="noreferrer noopener" title={hash}>
      {text} ↗
    </a>
  ) : (
    <span title={hash}>{text}</span>
  );
}

/** One line for a transaction the app sends: wallet → submitted → confirming → confirmed / failed. */
export function TxStatus({ state, chainId, onRetry }: { state: TxState; chainId: number; onRetry?: () => void }) {
  const l = txLine(state);
  if (l.tone === "idle") return null;
  const v = l.tone === "busy" ? "busy" : l.tone;
  return (
    <div className="txs" data-v={v} role="status" aria-live="polite">
      {l.step && <span className="step">{l.step} ·</span>}
      <span>{l.text}</span>
      {l.hash && <TxLink chainId={chainId} hash={l.hash} />}
      {l.retry && onRetry && (
        <button type="button" onClick={onRetry}>
          retry
        </button>
      )}
    </div>
  );
}

/** The order card's one status line: Signing… → Posted → Fill submitted · tx ↗ → Filled · tx ↗. */
export function OrderStatusLine({ line, chainId }: { line: PhaseLine; chainId: number }) {
  const v = line.tone === "done" ? "filled" : line.tone === "dim" ? "expired" : line.tone === "warn" ? "failed" : "busy";
  return (
    <div className="txs" data-v={v} role="status" aria-live="polite">
      <span>{line.text}</span>
      {line.tx && <TxLink chainId={chainId} hash={line.tx} />}
    </div>
  );
}
