import { useEffect, useState } from "react";

import { msg, t } from "../i18n";
import { marketTrack, type TrackArgs, type TrackStage } from "../lib/marketTrack";

const STEPS: { stage: TrackStage; label: string }[] = [
  { stage: "posted", label: msg("Posted") },
  { stage: "matching", label: msg("Matching") },
  { stage: "sent", label: msg("Fill sent") },
  { stage: "filled", label: msg("Filled") },
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
  const track = marketTrack({ ...props, now });
  const at = ORDER[track.stage];
  return (
    <div className="mtrack" data-stage={track.stage} data-late={track.late || undefined} role="status" aria-live="polite">
      <div className="mt-head">
        <span className="mt-title">
          {live && <i className="mt-orb" aria-hidden />}
          {track.stage === "filled" && <i className="mt-check" aria-hidden>✓</i>}
          {track.headline}
        </span>
        {track.etaSeconds !== null && track.etaSeconds > 0 && track.stage !== "sent" && <span className="mt-eta">{track.etaSeconds}s</span>}
      </div>
      <ol className="mt-steps">
        {STEPS.map((s, i) => (
          <li key={s.stage} data-s={at < 0 ? "dead" : i < at ? "done" : i === at ? "now" : "todo"}>
            <i />
            <span>{t(s.label)}</span>
          </li>
        ))}
      </ol>
      <div className="mt-bar" aria-hidden>
        <b style={{ width: `${(track.progress * 100).toFixed(1)}%` }} />
      </div>
      <div className="mt-sub">
        <span>{track.sub}</span>
        {live && (
          <span className="mt-auction" title={t("How far the Dutch auction has moved from your quote toward your minimum")}>
            {t("auction {pct}%", { pct: (track.auctionPct * 100).toFixed(0) })}
          </span>
        )}
      </div>
    </div>
  );
}

/** The open-orders status cell of a live market order: a pulsing "matching" with its countdown. */
export function MarketRowStatus(props: Omit<TrackArgs, "now">) {
  const now = useNow(true);
  const track = marketTrack({ ...props, now });
  return (
    <span className="st mrow" data-v={track.stage} data-late={track.late || undefined} title={track.sub}>
      <i className="mt-orb" aria-hidden />
      {track.stage === "sent" ? t("confirming") : track.late ? t("slow") : t("matching")}
      {track.etaSeconds !== null && track.etaSeconds > 0 && <em>{track.etaSeconds}s</em>}
    </span>
  );
}
