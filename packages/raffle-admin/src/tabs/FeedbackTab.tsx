import { useCallback, useEffect, useMemo, useState } from "react";
import type { Question } from "@1delta-x/sdk";

import { entriesCsv, tallyFeedback, type AdminApi, type AdminEntry } from "../adminApi";
import { errorText, short, utc } from "../AdminApp";

/** Every participation form of a promotion: the tallies per question, then each entry in full. */
export function FeedbackTab({ api, promotion }: { api: AdminApi; promotion: string }) {
  const [data, setData] = useState<{ questions: Question[]; entries: AdminEntry[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");

  const load = useCallback(async () => {
    try {
      const r = await api.entries(promotion);
      setData({ questions: r.questions, entries: r.entries });
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  }, [api, promotion]);
  useEffect(() => void load(), [load]);

  const tallies = useMemo(() => (data ? tallyFeedback(data.questions, data.entries) : []), [data]);
  const shown = useMemo(() => (data?.entries ?? []).filter((e) => !filter || JSON.stringify(e).toLowerCase().includes(filter.toLowerCase())), [data, filter]);

  const download = () => {
    if (!data) return;
    const url = URL.createObjectURL(new Blob([entriesCsv(data.questions, data.entries)], { type: "text/csv" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = `${promotion}-feedback.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (error) return <p className="signerr">{error}</p>;
  if (!data) return <p className="pqnote">Loading…</p>;
  const manual = data.entries.filter((e) => e.source === "manual").length;

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">
            {promotion} · {data.entries.length} entries{manual ? ` (${manual} added by hand)` : ""}
          </span>
          <span className="adrow">
            <button type="button" className="linkbtn" onClick={() => void load()}>
              Refresh
            </button>
            <button type="button" className="linkbtn" onClick={download} disabled={!data.entries.length}>
              Download CSV
            </button>
          </span>
        </div>
        <div className="boxbody adtallies">
          {data.entries.length === 0 && <p className="pqnote">No entries yet.</p>}
          {data.entries.length > 0 &&
            tallies.map((t) => (
              <div key={t.q.id} className="adtally">
                <span className="pqlabel">
                  {t.q.label} <span className="pqopt-tag">· {t.answered} answered</span>
                </span>
                {t.kind === "texts" ? (
                  <ul className="adtexts">
                    {t.texts.length === 0 && <li className="pqfine">—</li>}
                    {t.texts.map((x) => (
                      <li key={x.address}>
                        <span className="m pqfine">{short(x.address)}</span> {x.text}
                      </li>
                    ))}
                  </ul>
                ) : (
                  <>
                    {t.kind === "scale" && <span className="m">average {t.average === null ? "—" : t.average.toFixed(2)} / 5</span>}
                    <Bars counts={t.counts} total={Math.max(1, t.answered)} />
                  </>
                )}
              </div>
            ))}
        </div>
      </section>

      <section className="box">
        <div className="boxhead">
          <span className="lbl">Entries</span>
          <input className="pqtext m adfilter" placeholder="filter (address, answer, note…)" value={filter} onChange={(e) => setFilter(e.target.value)} />
        </div>
        <div className="sx">
          <table className="adtable">
            <thead>
              <tr>
                <th>Address</th>
                <th>Entered</th>
                <th>Source</th>
                <th>Contact</th>
                {data.questions
                  .filter((q) => q.id !== "contact")
                  .map((q) => (
                    <th key={q.id} title={q.label}>
                      {q.id}
                    </th>
                  ))}
              </tr>
            </thead>
            <tbody>
              {shown.map((e) => (
                <tr key={e.address}>
                  <td className="m" title={e.address}>
                    {short(e.address)}
                  </td>
                  <td className="m">{utc(e.enteredAt)}</td>
                  <td title={e.note ?? ""}>{e.source === "manual" ? `manual: ${e.note ?? ""}` : "signed"}</td>
                  <td>{e.contact ?? ""}</td>
                  {data.questions
                    .filter((q) => q.id !== "contact")
                    .map((q) => {
                      const v = e.answers[q.id];
                      return <td key={q.id}>{v === undefined ? "" : Array.isArray(v) ? v.join(", ") : String(v)}</td>;
                    })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function Bars({ counts, total }: { counts: Array<[string, number]>; total: number }) {
  return (
    <div className="adbars">
      {counts.map(([label, n]) => (
        <div key={label} className="adbar">
          <span className="adbarlabel">{label}</span>
          <span className="adbartrack">
            <i style={{ width: `${(n / total) * 100}%` }} />
          </span>
          <span className="m">{n}</span>
        </div>
      ))}
    </div>
  );
}
