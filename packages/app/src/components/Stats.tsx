import { fmtAmt } from "../lib/format";
import { depth } from "../lib/ladder";
import { SOURCE_NAME, type Level, type Venue } from "../lib/types";

interface StatsProps {
  bids: Level[];
  asks: Level[];
  base: string;
  venues: Venue[];
}

function Stat({ cap, value, sub, hero }: { cap: string; value: string; sub: string; hero?: boolean }) {
  return (
    <div className={`stat${hero ? " hero" : ""}`}>
      <span className="lbl">{cap}</span>
      <span className="v">{value}</span>
      <span className="cap">{sub}</span>
    </div>
  );
}

/**
 * Depth is measured on the bid side. That is the side an exit uses, and it is
 * the side where signed orders show up as depth the pool does not have.
 */
export function Stats({ bids, asks, base, venues }: StatsProps) {
  const bid = depth(bids);
  const ask = depth(asks);
  // Every AMM venue gets its own tile: the point of aggregating two pools is
  // seeing how much each one actually brought, not a combined "DEX" number.
  const amm = venues.filter((v) => !v.error);
  // A synthetic market's rungs are all ROUTE (composed over its hops' pools): one
  // route tile, with the hops it walks, instead of per-pool tiles that would read 0.
  const routed = amm.some((v) => v.hop);
  const pooled = routed ? bid.bySource.ROUTE : amm.reduce((n, v) => n + (bid.bySource[v.source] ?? 0), 0);
  const ratio = pooled > 0 ? `${(bid.total / pooled).toFixed(2)}×` : "—";
  const hops = [...new Set(amm.map((v) => v.hop).filter(Boolean))];

  return (
    <div className="stats">
      {routed && (
        <Stat cap="Routed bid depth" value={fmtAmt(bid.bySource.ROUTE)} sub={`${base} · ${hops.join(" → ")} · ${amm.length} pools`} />
      )}
      {!routed && amm.map((v) => (
        <Stat
          key={v.pool}
          cap={`${SOURCE_NAME[v.source]} bid depth`}
          value={fmtAmt(bid.bySource[v.source] ?? 0)}
          sub={`${base} · ${(v.feeBps / 10_000).toFixed(2)}% · ${v.pool.slice(0, 8)}…`}
        />
      ))}
      <Stat cap="Signed limit orders" value={fmtAmt(bid.bySource.LMT)} sub="resting on the bid side" />
      <Stat cap="Ask depth" value={fmtAmt(ask.total)} sub={`${base} offered`} />
      <Stat cap="Full book" value={ratio} sub={`${fmtAmt(bid.total)} ${base} against the pools alone`} hero />
    </div>
  );
}
