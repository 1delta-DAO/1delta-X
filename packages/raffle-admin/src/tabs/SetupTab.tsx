import { useEffect, useState } from "react";

import { NO_END, type AdminApi, type AdminConfig, type RaffleConfig } from "../adminApi";
import { errorText, parseAddresses, utc } from "../AdminApp";
import { DateTimeField, useZone, ZoneSwitch } from "../DateTimeField";
import { fromUnix, toUnix } from "../time";

const nowSec = () => Math.floor(Date.now() / 1000);
const DAY = 86_400;

/**
 * The live switch and the few settings the desk keeps: the promotion id (the feedback
 * forms' key), the window the app shows the notice in, the daily qualifier the
 * Qualifiers tab uses, and the addresses it leaves out. The deploy's `RAFFLE_*` are
 * the defaults; saving here overrides them without a deploy.
 */
export function SetupTab({ api, config, onChanged, onError }: { api: AdminApi; config: AdminConfig; onChanged: () => Promise<void>; onError: (e: string | null) => void }) {
  const base = config.effective ?? config.env;
  const [id, setId] = useState(base?.id ?? "rootstock-beta-1");
  const [zone, setZone] = useZone();
  const [start, setStart] = useState<number | null>(base && base.startsAt > 0 ? base.startsAt : null);
  const [end, setEnd] = useState<number | null>(base && base.endsAt < NO_END ? base.endsAt : null);
  const [qualifier, setQualifier] = useState(String(base?.qualifierUsd ?? 20));
  const [exclude, setExclude] = useState((base?.exclude ?? []).join("\n"));
  const [busy, setBusy] = useState(false);
  const [resetId, setResetId] = useState("");
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => setNote(null), [id, start, end, qualifier, exclude]);

  const ex = parseAddresses(exclude);
  const draft: RaffleConfig = { id: id.trim(), startsAt: start ?? 0, endsAt: end ?? NO_END, qualifierUsd: Number(qualifier), exclude: ex.ok };
  const badWindow = start !== null && end !== null && end <= start;

  const run = async (f: () => Promise<unknown>, done?: string) => {
    setBusy(true);
    onError(null);
    try {
      await f();
      await onChanged();
      if (done) setNote(done);
    } catch (e) {
      onError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">Live switch</span>
          <span className="lbl">
            now: <b>{config.effective ? (config.live ? "LIVE" : "closed (outside the window)") : config.source === "disabled" ? "switched off" : "no draw"}</b> · source: {config.source}
          </span>
        </div>
        <div className="boxbody">
          <p className="pqnote">
            While live, the app shows the prize-draw notice and the optional feedback form. The draw itself is yours: list the day
            under Qualifiers, pick by hand, announce by address, pay. The wording in the app stays vague on purpose (the Terms leave
            criteria, timing and amounts to 1delta), so be generous with edge cases.
          </p>
          <label className="pq">
            <span className="pqlabel">Promotion id</span>
            <input className="pqtext m" value={id} onChange={(e) => setId(e.target.value)} placeholder="rootstock-beta-1" />
            <span className="pqfine">Lower-case, digits, dashes. Feedback is kept per id; a new id starts a clean Feedback tab.</span>
          </label>
          <ZoneSwitch zone={zone} onChange={setZone} />
          <div className="adrow adtimes">
            <DateTimeField
              label="Starts"
              hint="fills before this do not unlock the feedback form"
              value={start}
              onChange={setStart}
              zone={zone}
              empty="Open from the beginning"
              presets={[
                { label: "Now", value: nowSec },
                { label: "Today 00:00", value: () => toUnix(fromUnix(nowSec(), zone).date, "00:00", zone) },
                { label: "Clear", value: () => null },
              ]}
            />
            <DateTimeField
              label="Notice goes dark"
              hint="a date alone means 23:59 that day; leave empty while the pot lasts"
              defaultTime="23:59"
              warnIfPast
              value={end}
              onChange={setEnd}
              zone={zone}
              empty="No end: switch off by hand when the pot is paid out"
              presets={[
                { label: "+10 days", value: () => (start ?? nowSec()) + 10 * DAY },
                { label: "+14 days", value: () => (start ?? nowSec()) + 14 * DAY },
                { label: "Clear", value: () => null },
              ]}
            />
          </div>
          {badWindow && <p className="warn pqfine">The end is before the start.</p>}
          <label className="pq adnarrow">
            <span className="pqlabel">Daily qualifier, $</span>
            <input className="pqtext m" inputMode="decimal" value={qualifier} onChange={(e) => setQualifier(e.target.value)} />
            <span className="pqfine">What the Qualifiers tab marks as ✓. The notice says "about" this amount.</span>
          </label>
          <label className="pq">
            <span className="pqlabel">
              Excluded from the qualifier list <span className="pqopt-tag">· team, contractors, ambassadors (TC §3.3); our fillers are always excluded</span>
            </span>
            <textarea className="pqtext m" rows={5} value={exclude} onChange={(e) => setExclude(e.target.value)} placeholder="0x… one per line" />
            {ex.bad.length > 0 && <span className="warn pqfine">Not addresses: {ex.bad.join(", ")}</span>}
          </label>
          {note && <p className="good pqfine">{note}</p>}
          <div className="adrow">
            <button type="button" className="cta" disabled={busy || ex.bad.length > 0 || !id.trim() || badWindow || !Number.isFinite(Number(qualifier))} onClick={() => run(() => api.saveConfig(draft), "Saved. The app follows within a minute.")}>
              Save &amp; switch on
            </button>
            <button type="button" className="cta line" disabled={busy || config.source === "disabled"} onClick={() => run(() => api.disable(), "Switched off: no notice, no feedback form.")}>
              Switch off
            </button>
            <button type="button" className="cta line" disabled={busy || config.source === "env" || !config.env} onClick={() => run(() => api.revertToEnv(), "Back to the deploy defaults (RAFFLE_*).")}>
              Use deploy defaults
            </button>
          </div>
          {config.env && (
            <p className="pqfine">
              Deploy defaults: {config.env.id} · {utc(config.env.startsAt)} → {utc(config.env.endsAt)} · ${config.env.qualifierUsd}/day
            </p>
          )}
        </div>
      </section>

      <section className="box addanger">
        <div className="boxhead">
          <span className="lbl">Reset</span>
        </div>
        <div className="boxbody">
          <label className="pq">
            <span className="pqlabel">Delete every feedback form of a promotion (after a rehearsal)</span>
            <input className="pqtext m" value={resetId} onChange={(e) => setResetId(e.target.value)} placeholder="type the promotion id to confirm" />
          </label>
          <button
            type="button"
            className="cta line"
            disabled={busy || !resetId.trim()}
            onClick={() =>
              window.confirm(`Delete every feedback form of "${resetId.trim()}"? This cannot be undone.`) &&
              run(async () => {
                const r = await api.reset(resetId.trim(), resetId.trim());
                setNote(`Reset ${resetId.trim()}: ${r.entriesRemoved} feedback form(s) removed.`);
                setResetId("");
              })
            }
          >
            Reset promotion
          </button>
        </div>
      </section>
    </div>
  );
}
