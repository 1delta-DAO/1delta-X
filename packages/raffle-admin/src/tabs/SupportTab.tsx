import { useState } from "react";
import { isAddress } from "viem";

import type { AdminApi, AdminConfig, AdminEntry, Claim, Win } from "../adminApi";
import { errorText, short, utc } from "../AdminApp";

type Lookup = { address: string; fills: number; firstFillAt: number | null; entered: boolean; entry?: AdminEntry; wins: Win[]; claims: Claim[] };

/**
 * Support cases. Look an address up: its fills on the book, its feedback, the draws it
 * won and whether it has claimed. A winner who confirmed eligibility another way (a
 * signed message in Telegram, a call) is recorded here with a note. Feedback can be
 * removed on request (a data-deletion case). There is nothing to "add to the draw":
 * the Terms (§4.1) promise no registration, every trader is in.
 */
export function SupportTab({ api, promotion, config }: { api: AdminApi; promotion: string; config: AdminConfig }) {
  const [address, setAddress] = useState("");
  const [found, setFound] = useState<Lookup | null>(null);
  const [note, setNote] = useState("");
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

  const unclaimed = found?.wins.filter((w) => !w.claimed) ?? [];

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
              <div className="pqrow">
                <dt>Draws won</dt>
                <dd className="m">
                  {found.wins.length === 0
                    ? "none"
                    : found.wins.map((w) => (
                        <div key={w.day}>
                          {w.day}: {w.payout} {w.token} · {w.claimed ? `claimed ${utc(w.claimedAt ?? 0)}` : `unclaimed, window until ${utc(w.claimBy)}`}
                        </div>
                      ))}
                </dd>
              </div>
            </dl>
          )}
          {msg && <p className={msg.ok ? "good pqfine" : "signerr"}>{msg.text}</p>}
        </div>
      </section>

      {found && unclaimed.length > 0 && (
        <section className="box">
          <div className="boxhead">
            <span className="lbl">Confirm a claim by hand</span>
          </div>
          <div className="boxbody">
            {notRunning && <p className="warn pqfine">You are editing "{promotion}", which is not the running promotion.</p>}
            <p className="pqnote">
              For a winner who confirmed eligibility (TC §3, §7.5) outside the app, e.g. with a signed message on Telegram after
              the 14-day window. The note says how; the payout review still happens.
            </p>
            <label className="pq">
              <span className="pqlabel">Note (required)</span>
              <input className="pqtext" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Signed message in Telegram, 2026-10-30, link…" />
            </label>
            <div className="adrow">
              {unclaimed.map((w) => (
                <button
                  key={w.day}
                  type="button"
                  className="cta"
                  disabled={busy || !note.trim()}
                  onClick={() =>
                    act(async () => {
                      await api.confirmClaim({ address: found.address, day: w.day, note: note.trim() }, promotion);
                      setNote("");
                      return `Claim for ${w.day} recorded.`;
                    })
                  }
                >
                  Confirm {w.day} ({w.payout} {w.token})
                </button>
              ))}
            </div>
          </div>
        </section>
      )}

      {found && (found.claims.length > 0 || found.entry) && (
        <section className="box">
          <div className="boxhead">
            <span className="lbl">Records to remove</span>
          </div>
          <div className="boxbody">
            <div className="adrow">
              {found.claims.map((c) => (
                <button
                  key={c.day}
                  type="button"
                  className="cta line"
                  disabled={busy}
                  onClick={() =>
                    window.confirm(`Remove the ${c.day} claim of ${short(found.address)} (${c.source}${c.note ? `: ${c.note}` : ""})?`) &&
                    act(async () => (await api.removeClaim(c.day, found.address, promotion), `Claim for ${c.day} removed.`))
                  }
                >
                  Remove {c.day} claim
                </button>
              ))}
              {found.entry && (
                <button
                  type="button"
                  className="cta line"
                  disabled={busy}
                  onClick={() => window.confirm(`Delete the feedback of ${found.address}? Its answers are gone for good.`) && act(async () => (await api.removeEntry(found.address, promotion), "Feedback deleted."))}
                >
                  Delete feedback
                </button>
              )}
            </div>
          </div>
        </section>
      )}
    </div>
  );
}
