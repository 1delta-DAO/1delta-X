import { useEffect, useState } from "react";

import { marketTrack, type TrackArgs, type TrackStage } from "../lib/marketTrack";

const STEPS: { stage: TrackStage; label: string }[] = [
  { stage: "posted", label: "Posted" },
  { stage: "matching", label: "Matching" },
  { stage: "sent", label: "Fill sent" },
  { stage: "filled", label: "Filled" },
];
const ORDER: Record<TrackStage, number> = { posted: 0, matching: 1, sent: 2, filled: 3, ended: -1 };

/** Re-render on a clock while the order is live. */
function useNow(live: boolean, ms = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [live, ms]);
  return now;
}

/** A market order's live track: Posted → Matching → Fill sent → Filled, with an ETA. */
export function MarketFillTrack(props: Omit<TrackArgs, "now">) {
  const k = props.phase.kind;
  const live = k === "signing" || k === "posting" || k === "posted" || k === "fill-pending";
  const now = useNow(live);
  const t = marketTrack({ ...props, now });
  const at = ORDER[t.stage];
  return (
    <div className="mtrack" data-stage={t.stage} data-late={t.late || undefined} role="status" aria-live="polite">
      <div className="mt-head">
        <span className="mt-title">
          {live && <i className="mt-orb" aria-hidden />}
          {t.stage === "filled" && <i className="mt-check" aria-hidden>✓</i>}
          {t.headline}
        </span>
        {t.etaSeconds !== null && t.etaSeconds > 0 && t.stage !== "sent" && <span className="mt-eta">{t.etaSeconds}s</span>}
      </div>
      <ol className="mt-steps">
        {STEPS.map((s, i) => (
          <li key={s.stage} data-s={at < 0 ? "dead" : i < at ? "done" : i === at ? "now" : "todo"}>
            <i />
            <span>{s.label}</span>
          </li>
        ))}
      </ol>
      <div className="mt-bar" aria-hidden>
        <b style={{ width: `${(t.progress * 100).toFixed(1)}%` }} />
      </div>
      <div className="mt-sub">
        <span>{t.sub}</span>
        {live && (
          <span className="mt-auction" title="How far the Dutch auction has moved from your quote toward your minimum">
            auction {(t.auctionPct * 100).toFixed(0)}%
          </span>
        )}
      </div>
    </div>
  );
}

/** The open-orders status cell of a live market order: a pulsing "matching" with its countdown. */
export function MarketRowStatus(props: Omit<TrackArgs, "now">) {
  const now = useNow(true);
  const t = marketTrack({ ...props, now });
  return (
    <span className="st mrow" data-v={t.stage} data-late={t.late || undefined} title={t.sub}>
      <i className="mt-orb" aria-hidden />
      {t.stage === "sent" ? "confirming" : t.late ? "slow" : "matching"}
      {t.etaSeconds !== null && t.etaSeconds > 0 && <em>{t.etaSeconds}s</em>}
    </span>
  );
}
