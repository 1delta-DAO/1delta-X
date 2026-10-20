import { useState } from "react";
import { isAddress } from "viem";

import type { AdminApi, AdminConfig, AdminEntry } from "../adminApi";
import { errorText, utc } from "../AdminApp";

type Lookup = { address: string; fills: number; firstFillAt: number | null; entered: boolean; entry?: AdminEntry };

/**
 * Support cases. Look an address up (its fills on the book, its entry), add it by hand
 * when it should have been entered ("I signed and I'm not listed" — the note says why),
 * or remove an entry (a wrong address, a disqualification).
 */
export function SupportTab({ api, promotion, config }: { api: AdminApi; promotion: string; config: AdminConfig }) {
  const [address, setAddress] = useState("");
  const [found, setFound] = useState<Lookup | null>(null);
  const [note, setNote] = useState("");
  const [enteredAt, setEnteredAt] = useState("");
  const [overwrite, setOverwrite] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const valid = isAddress(address.trim(), { strict: false });
  const notRunning = promotion !== config.effective?.id;

  const act = async (f: () => Promise<string>) => {
    setBusy(true);
    setMsg(null);
    try {
      setMsg({ ok: true, text: await f() });
      setFound(await api.lookup(address.trim(), promotion));
    } catch (e) {
      setMsg({ ok: false, text: errorText(e) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">Look up an address · {promotion}</span>
        </div>
        <div className="boxbody">
          <div className="adrow">
            <input className="pqtext m" placeholder="0x…" value={address} onChange={(e) => (setAddress(e.target.value), setFound(null), setMsg(null))} />
            <button type="button" className="cta line" disabled={!valid || busy} onClick={() => act(async () => "Found.")}>
              Look up
            </button>
          </div>
          {found && (
            <dl className="sum">
              <div className="pqrow">
                <dt>Fills on the book (as maker, all time)</dt>
                <dd className="m">{found.fills}</dd>
              </div>
              <div className="pqrow">
                <dt>First fill since the promotion start</dt>
                <dd className="m">{found.firstFillAt === null ? "none — Participate never unlocked for it" : utc(found.firstFillAt)}</dd>
              </div>
              <div className="pqrow">
                <dt>Entry</dt>
                <dd className="m">
                  {found.entry ? `${found.entry.source} · ${utc(found.entry.enteredAt)}${found.entry.note ? ` · ${found.entry.note}` : ""}` : "not entered"}
                </dd>
              </div>
            </dl>
          )}
          {msg && <p className={msg.ok ? "good pqfine" : "signerr"}>{msg.text}</p>}
        </div>
      </section>

      {found && (
        <section className="box">
          <div className="boxhead">
            <span className="lbl">{found.entered ? "Change the entry" : "Add by hand"}</span>
          </div>
          <div className="boxbody">
            {notRunning && <p className="warn pqfine">You are editing "{promotion}", which is not the running promotion.</p>}
            {found.firstFillAt === null && <p className="warn pqfine">This address has no fill since the start — the desk would not have let it enter.</p>}
            <label className="pq">
              <span className="pqlabel">Note (required — why, e.g. support ticket)</span>
              <input className="pqtext" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Ticket #12: signed on 10-24, entry missing" />
            </label>
            <label className="pq">
              <span className="pqlabel">
                Entered at (UTC) <span className="pqopt-tag">· optional; the draw counts entrants entered by its snapshot</span>
              </span>
              <input className="pqtext m" type="datetime-local" value={enteredAt} onChange={(e) => setEnteredAt(e.target.value)} />
            </label>
            {found.entry?.source === "signed" && (
              <label className="check">
                <input type="checkbox" checked={overwrite} onChange={(e) => setOverwrite(e.target.checked)} />
                <span>Replace the user&rsquo;s signed answers with a manual entry (their feedback is dropped)</span>
              </label>
            )}
            <div className="adrow">
              <button
                type="button"
                className="cta"
                disabled={busy || !note.trim() || (found.entry?.source === "signed" && !overwrite)}
                onClick={() =>
                  act(async () => {
                    await api.addManual({ address: found.address, note: note.trim(), ...(enteredAt ? { enteredAt: Math.floor(Date.parse(`${enteredAt}:00Z`) / 1000) } : {}), overwrite }, promotion);
                    setNote("");
                    return "Entered by hand.";
                  })
                }
              >
                {found.entered ? "Save manual entry" : "Add to the draw"}
              </button>
              {found.entered && (
                <button
                  type="button"
                  className="cta line"
                  disabled={busy}
                  onClick={() =>
                    window.confirm(`Remove ${found.address} from "${promotion}"?`) &&
                    act(async () => {
                      await api.removeEntry(found.address, promotion);
                      return "Entry removed.";
                    })
                  }
                >
                  Remove entry
                </button>
              )}
            </div>
          </div>
        </section>
      )}
    </div>
  );
}
