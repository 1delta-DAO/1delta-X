import { fmtAmt } from "../lib/format";
import { depth } from "../lib/ladder";
import type { Level } from "../lib/types";

interface StatsProps {
  bids: Level[];
  asks: Level[];
  base: string;
  venue: string;
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
export function Stats({ bids, asks, base, venue }: StatsProps) {
  const bid = depth(bids);
  const ask = depth(asks);
  const ratio = bid.bySource.DEX > 0 ? `${(bid.total / bid.bySource.DEX).toFixed(2)}×` : "—";

  return (
    <div className="stats">
      <Stat cap="Pool bid depth" value={fmtAmt(bid.bySource.DEX)} sub={`${base} · ${venue}`} />
      <Stat cap="Signed limit orders" value={fmtAmt(bid.bySource.LMT)} sub="resting on the bid side" />
      <Stat cap="Ask depth" value={fmtAmt(ask.total)} sub={`${base} offered`} />
      <Stat cap="Full book" value={ratio} sub={`${fmtAmt(bid.total)} ${base} against the pool alone`} hero />
    </div>
  );
}
