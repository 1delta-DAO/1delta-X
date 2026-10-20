import { useMemo, useState } from "react";

import { NATIVE_SYMBOL, WRAPPED_NATIVE } from "../config/markets";
import { useAllFills } from "../hooks/useAllFills";
import {
  dashStats,
  fillerName,
  toDashFill,
  type Breakdown,
  type DashFill,
} from "../lib/dashboard";
import { fmtUsd } from "../lib/usdPrices";
import { explorerTx } from "../lib/txFlow";

interface DashboardProps {
  chainId: number;
  /** USD per one token, by config symbol (App's `usdOf`). */
  usdOf: (symbol: string) => number | undefined;
}

const DAYS = 30;
const RECENT = 50;

const usd = (v: number) => (v === 0 ? "$0" : fmtUsd(v));
const amt = (v: number) =>
  v >= 1000
    ? v.toLocaleString("en-US", { maximumFractionDigits: 0 })
    : v >= 1
      ? v.toFixed(2)
      : v.toPrecision(3);
const day = (ms: number) =>
  new Date(ms).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
const when = (ms: number | null) =>
  ms === null
    ? "—"
    : new Date(ms).toLocaleString("en-US", {
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      });

function Kpi({
  label,
  value,
  sub,
}: {
  label: string;
  value: string;
  sub?: string;
}) {
  return (
    <div className="kpi">
      <span className="lbl">{label}</span>
      <span className="v m">{value}</span>
      {sub && <span className="s m">{sub}</span>}
    </div>
  );
}

/** Daily USD volume, one bar per UTC day; hover (or tap) a day for its figures. */
function DailyChart({
  daily,
}: {
  daily: { day: number; usd: number; fills: number }[];
}) {
  const [hover, setHover] = useState<number | null>(null);
  const max = Math.max(0, ...daily.map((d) => d.usd));
  const h = hover === null ? null : daily[hover];
  return (
    <div className="chart">
      <div className="charthead">
        <span className="lbl">
          Daily volume · last {daily.length} days (UTC)
        </span>
        <span className="m tip">
          {h
            ? `${day(h.day)} · ${usd(h.usd)} · ${h.fills} fill${h.fills === 1 ? "" : "s"}`
            : `peak ${usd(max)}`}
        </span>
      </div>
      <div
        className="bars"
        role="img"
        aria-label="Daily fill volume in USD"
        onMouseLeave={() => setHover(null)}
      >
        {daily.map((d, i) => (
          // The hit target is the whole column, not just the bar.
          <div
            key={d.day}
            className="col"
            onMouseEnter={() => setHover(i)}
            onClick={() => setHover(i)}
          >
            {d.usd > 0 && (
              <i
                className={hover === i ? "on" : undefined}
                style={{ height: `${max > 0 ? (d.usd / max) * 100 : 0}%` }}
              />
            )}
          </div>
        ))}
      </div>
      <div className="ticks m">
        {daily.map((d, i) => (
          <span key={d.day}>
            {(daily.length - 1 - i) % 7 === 0 ? day(d.day) : ""}
          </span>
        ))}
      </div>
    </div>
  );
}

function BreakdownTable({
  title,
  rows,
  total,
}: {
  title: string;
  rows: Breakdown[];
  total: number;
}) {
  return (
    <div className="box">
      <div className="boxhead">
        <span className="lbl">{title}</span>
      </div>
      <div className="sx">
        <table className="o">
          <thead>
            <tr>
              <th>{title.replace(/^By /, "")}</th>
              <th>Fills</th>
              <th>Volume</th>
              <th>Share</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td className="empty" colSpan={4}>
                  No fills yet.
                </td>
              </tr>
            ) : (
              rows.map((r) => {
                const share = total > 0 ? r.usd / total : 0;
                return (
                  <tr key={r.key}>
                    <td>{r.key}</td>
                    <td>{r.fills}</td>
                    <td>{usd(r.usd)}</td>
                    <td>
                      <span className="share">
                        <i style={{ width: `${Math.round(share * 100)}%` }} />
                      </span>
                      <span className="faint">
                        {(share * 100).toFixed(share < 0.1 ? 1 : 0)}%
                      </span>
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function RecentTable({
  chainId,
  fills,
}: {
  chainId: number;
  fills: DashFill[];
}) {
  return (
    <div className="box">
      <div className="boxhead">
        <span className="lbl">Latest fills · all makers</span>
      </div>
      <div className="sx">
        <table className="o">
          <thead>
            <tr>
              <th>Time</th>
              <th>Pair</th>
              <th>Size</th>
              <th>Volume</th>
              <th>Filled by</th>
              <th>Tx</th>
            </tr>
          </thead>
          <tbody>
            {fills.length === 0 ? (
              <tr>
                <td className="empty" colSpan={6}>
                  No fills yet.
                </td>
              </tr>
            ) : (
              fills.map((f) => {
                const href = f.tx ? explorerTx(chainId, f.tx) : null;
                return (
                  <tr key={f.id}>
                    <td className="faint">{when(f.at)}</td>
                    <td>
                      {f.pay} → {f.recv}
                    </td>
                    <td>
                      {f.anchor
                        ? `${amt(f.anchor.amount)} ${f.anchor.symbol}`
                        : "—"}
                    </td>
                    <td>{f.usd !== undefined ? usd(f.usd) : "—"}</td>
                    <td>{fillerName(chainId, f.solver)}</td>
                    <td>
                      {href ? (
                        <a href={href} target="_blank" rel="noreferrer">
                          {f.tx.slice(0, 8)}…
                        </a>
                      ) : (
                        "—"
                      )}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

/**
 * The analytics tab: every fill the orderbook indexed, its volume (the exactly-sized
 * anchor leg at today's USD price), per day, per pair and per filler.
 */
export function Dashboard({ chainId, usdOf }: DashboardProps) {
  const { fills: wire, loading, error, complete } = useAllFills(true);
  // The native coin prices as its wrapped token.
  const price = useMemo(
    () => (s: string) =>
      usdOf(s === NATIVE_SYMBOL[chainId] ? (WRAPPED_NATIVE[chainId] ?? s) : s),
    [usdOf, chainId],
  );
  const fills = useMemo(
    () => wire.map((f) => toDashFill(chainId, f, price)),
    [wire, chainId, price],
  );
  const stats = useMemo(
    () => dashStats(chainId, fills, Date.now(), DAYS),
    [chainId, fills],
  );
  const unsized = stats.fills - stats.sized;

  return (
    <div className="dash">
      <div className="box">
        <div className="boxhead">
          <span className="lbl">
            Dashboard · every fill on the 1delta X orderbook
          </span>
          <span className="lbl">
            {loading
              ? "loading…"
              : error
                ? error
                : `updated every minute${complete ? "" : " · oldest fills not loaded"}`}
          </span>
        </div>
        <div className="kpis">
          <Kpi
            label="Total volume"
            value={usd(stats.usd)}
            sub={`${stats.fills} fills`}
          />
          <Kpi
            label="Last 24 h"
            value={usd(stats.usd24h)}
            sub={`${stats.fills24h} fills`}
          />
          <Kpi
            label="Makers"
            value={String(stats.makers)}
            sub="distinct wallets"
          />
          <Kpi
            label="Avg fill"
            value={stats.sized > 0 ? usd(stats.usd / stats.sized) : "—"}
            sub="per sized fill"
          />
        </div>
        <DailyChart daily={stats.daily} />
        <p className="dnote">
          Volume is the exactly-filled leg of each order (what a seller paid,
          what a buyer received) at today&apos;s USD price.
          {unsized > 0 &&
            ` ${unsized} older fill${unsized === 1 ? "" : "s"} could not be sized (the orderbook no longer holds the order).`}
        </p>
      </div>
      <div className="dgrid">
        <BreakdownTable title="By pair" rows={stats.pairs} total={stats.usd} />
        <BreakdownTable
          title="By filler"
          rows={stats.fillers}
          total={stats.usd}
        />
      </div>
      <RecentTable chainId={chainId} fills={fills.slice(0, RECENT)} />
    </div>
  );
}
