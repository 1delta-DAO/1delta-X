import { useMemo, useState } from "react";

import { NATIVE_SYMBOL, WRAPPED_NATIVE } from "../config/markets";
import { useAllFills } from "../hooks/useAllFills";
import { useTxHops } from "../hooks/useTxHops";
import { t, useLang } from "../i18n";
import {
  dashStats,
  fillerName,
  toDashFill,
  tokenUsd,
  type Breakdown,
  type DashFill,
} from "../lib/dashboard";
import { fmtUsd } from "../lib/usdPrices";
import { explorerTx } from "../lib/txFlow";
import { hopUsd } from "../lib/turnover";

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
  daily: { day: number; volume: number; turnover: number; fills: number }[];
}) {
  const [hover, setHover] = useState<number | null>(null);
  const max = Math.max(0, ...daily.map((d) => d.volume));
  const h = hover === null ? null : daily[hover];
  return (
    <div className="chart">
      <div className="charthead">
        <span className="lbl">
          {t("Daily volume · last {n} days (UTC)", { n: daily.length })}
        </span>
        <span className="m tip">
          {h
            ? h.fills === 1
              ? t("{day} · volume {volume} · turnover {turnover} · {n} fill", {
                  day: day(h.day),
                  volume: usd(h.volume),
                  turnover: usd(h.turnover),
                  n: h.fills,
                })
              : t("{day} · volume {volume} · turnover {turnover} · {n} fills", {
                  day: day(h.day),
                  volume: usd(h.volume),
                  turnover: usd(h.turnover),
                  n: h.fills,
                })
            : t("peak {max}", { max: usd(max) })}
        </span>
      </div>
      <div
        className="bars"
        role="img"
        aria-label={t("Daily fill volume in USD")}
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
            {d.volume > 0 && (
              <i
                className={hover === i ? "on" : undefined}
                style={{ height: `${max > 0 ? (d.volume / max) * 100 : 0}%` }}
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
  column,
  rows,
  total,
}: {
  title: string;
  column: string;
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
              <th>{column}</th>
              <th>{t("Fills")}</th>
              <th>{t("Volume")}</th>
              <th>{t("Turnover")}</th>
              <th>{t("Share")}</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 ? (
              <tr>
                <td className="empty" colSpan={5}>
                  {t("No fills yet.")}
                </td>
              </tr>
            ) : (
              rows.map((r) => {
                const share = total > 0 ? r.volume / total : 0;
                return (
                  <tr key={r.key}>
                    <td>{r.key}</td>
                    <td>{r.fills}</td>
                    <td>{usd(r.volume)}</td>
                    <td className="faint">{usd(r.turnover)}</td>
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
        <span className="lbl">{t("Latest fills · all makers")}</span>
      </div>
      <div className="sx">
        <table className="o">
          <thead>
            <tr>
              <th>{t("Time")}</th>
              <th>{t("Pair")}</th>
              <th>{t("Size")}</th>
              <th>{t("Volume")}</th>
              <th>{t("Filled by")}</th>
              <th>{t("Tx")}</th>
            </tr>
          </thead>
          <tbody>
            {fills.length === 0 ? (
              <tr>
                <td className="empty" colSpan={6}>
                  {t("No fills yet.")}
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
  const lang = useLang();
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
  // TURNOVER: every pool hop each fill transaction ran (lib/turnover.ts), read from its receipt.
  const txs = useMemo(() => fills.map((f) => f.tx).filter(Boolean), [fills]);
  const { hops, pools, pending } = useTxHops(chainId, txs);
  const txTurnover = useMemo(() => {
    const out = new Map<string, number>();
    for (const [tx, h] of hops) {
      // No swap, or none we can price: its fills are its turnover.
      const usds = h
        .map((hop) =>
          hopUsd(hop, pools.get(hop.pool), (tok, w) =>
            tokenUsd(chainId, tok, w, price),
          ),
        )
        .filter((v): v is number => v !== undefined);
      if (usds.length > 0)
        out.set(
          tx,
          usds.reduce((a, v) => a + v, 0),
        );
    }
    return out;
  }, [hops, pools, chainId, price]);
  const stats = useMemo(
    () => dashStats(chainId, fills, Date.now(), DAYS, txTurnover),
    [chainId, fills, txTurnover, lang],
  );
  const unsized = stats.fills - stats.sized;

  return (
    <div className="dash">
      <div className="box">
        <div className="boxhead">
          <span className="lbl">
            {t("Dashboard · every fill on the 1delta X orderbook")}
          </span>
          <span className="lbl">
            {loading
              ? t("loading…")
              : error
                ? error
                : complete
                  ? t("updated every minute")
                  : t("updated every minute · oldest fills not loaded")}
          </span>
        </div>
        <div className="kpis">
          <Kpi
            label={t("Volume")}
            value={usd(stats.volume)}
            sub={t("netted · {n} fills", { n: stats.fills })}
          />
          <Kpi
            label={t("Turnover")}
            value={usd(stats.turnover)}
            sub={
              pending > 0
                ? pending === 1
                  ? t("reading {n} transaction…", { n: pending })
                  : t("reading {n} transactions…", { n: pending })
                : t("every conversion, incl. route hops")
            }
          />
          <Kpi
            label={t("Last 24 h")}
            value={usd(stats.volume24h)}
            sub={t("volume · {n} fills", { n: stats.fills24h })}
          />
          <Kpi
            label={t("Makers")}
            value={String(stats.makers)}
            sub={t("distinct wallets")}
          />
        </div>
        <DailyChart daily={stats.daily} />
        <p className="dnote">
          {t(
            "Each fill is sized on the exactly-filled leg of its order (what a seller paid, what a buyer received) at today's USD price. Volume is the USD that really changed hands: opposite fills settled in the same transaction net (two matched orders count once). Turnover is every conversion that ran: each pool hop of a routed fill (a two-hop route counts about twice), and the fill itself when it needed no swap (filled from inventory).",
          )}
          {unsized > 0 &&
            ` ${
              unsized === 1
                ? t("{n} older fill could not be sized (the orderbook no longer holds the order).", { n: unsized })
                : t("{n} older fills could not be sized (the orderbook no longer holds the order).", { n: unsized })
            }`}
        </p>
      </div>
      <div className="dgrid">
        <BreakdownTable
          title={t("By pair")}
          column={t("pair")}
          rows={stats.pairs}
          total={stats.volume}
        />
        <BreakdownTable
          title={t("By filler")}
          column={t("filler")}
          rows={stats.fillers}
          total={stats.volume}
        />
      </div>
      <RecentTable chainId={chainId} fills={fills.slice(0, RECENT)} />
    </div>
  );
}
