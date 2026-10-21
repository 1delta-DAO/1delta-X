import { useState } from "react";
import { isAddress } from "viem";

import type { AdminApi, AdminEntry } from "../adminApi";
import { errorText, utc } from "../AdminApp";

type Lookup = { address: string; fills: number; firstFillAt: number | null; entered: boolean; entry?: AdminEntry };

/**
 * Support cases. Look an address up: its fills on the book and its feedback. Feedback
 * can be removed on request (a data-deletion case). There is nothing to "add to the
 * draw": the Terms (§4.1) promise no registration, every trader is in.
 */
export function SupportTab({ api, promotion, onChanged }: { api: AdminApi; promotion: string; onChanged: () => Promise<void> }) {
  const [address, setAddress] = useState("");
  const [resetId, setResetId] = useState("");
  const [found, setFound] = useState<Lookup | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const valid = isAddress(address.trim(), { strict: false });

  const act = async (f: () => Promise<string>) => {
    setBusy(true);
    setMsg(null);
    try {
      setMsg({ ok: true, text: await f() });
      if (valid) setFound(await api.lookup(address.trim(), promotion));
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
                <dd className="m">{found.firstFillAt === null ? "none: not in any draw yet, feedback form locked" : utc(found.firstFillAt)}</dd>
              </div>
              <div className="pqrow">
                <dt>Feedback</dt>
                <dd className="m">{found.entry ? `given ${utc(found.entry.enteredAt)}${found.entry.updatedAt !== found.entry.enteredAt ? `, updated ${utc(found.entry.updatedAt)}` : ""}` : "none (optional)"}</dd>
              </div>
            </dl>
          )}
          {msg && <p className={msg.ok ? "good pqfine" : "signerr"}>{msg.text}</p>}
        </div>
      </section>

      {found?.entry && (
        <section className="box">
          <div className="boxhead">
            <span className="lbl">Data deletion</span>
          </div>
          <div className="boxbody">
            <div className="adrow">
              <button
                type="button"
                className="cta line"
                disabled={busy}
                onClick={() => window.confirm(`Delete the feedback of ${found.address}? Its answers are gone for good.`) && act(async () => (await api.removeEntry(found.address, promotion), await onChanged(), "Feedback deleted."))}
              >
                Delete feedback
              </button>
            </div>
          </div>
        </section>
      )}

      <section className="box addanger">
        <div className="boxhead">
          <span className="lbl">Reset after a rehearsal</span>
        </div>
        <div className="boxbody">
          <label className="pq">
            <span className="pqlabel">Delete every feedback form under a key (type it to confirm)</span>
            <input className="pqtext m" value={resetId} onChange={(e) => setResetId(e.target.value)} placeholder={promotion} />
          </label>
          <button
            type="button"
            className="cta line"
            disabled={busy || !resetId.trim()}
            onClick={() =>
              window.confirm(`Delete every feedback form under "${resetId.trim()}"? This cannot be undone.`) &&
              act(async () => {
                const r = await api.reset(resetId.trim(), resetId.trim());
                await onChanged();
                setResetId("");
                return `${r.entriesRemoved} feedback form(s) removed.`;
              })
            }
          >
            Reset
          </button>
        </div>
      </section>
    </div>
  );
}
