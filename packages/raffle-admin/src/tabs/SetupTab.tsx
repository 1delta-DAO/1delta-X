import { useEffect, useState } from "react";

import { NO_END, type AdminApi, type AdminConfig, type RaffleConfig } from "../adminApi";
import { errorText, parseAddresses, rsk, utc } from "../AdminApp";
import { DateTimeField, useZone, ZoneSwitch } from "../DateTimeField";
import { toUnix, fromUnix } from "../time";

const nowSec = () => Math.floor(Date.now() / 1000);
const DAY = 86_400;

interface Check {
  label: string;
  ok: boolean | null;
  detail: string;
}

export function SetupTab({ api, config, buildTerms, onChanged, onError }: { api: AdminApi; config: AdminConfig; buildTerms: `0x${string}`; onChanged: () => Promise<void>; onError: (e: string | null) => void }) {
  const base = config.effective ?? config.env;
  const [id, setId] = useState(base?.id ?? "");
  const [terms, setTerms] = useState<string>(base?.terms ?? buildTerms);
  const [zone, setZone] = useZone();
  // null = open from the start / no end.
  const [start, setStart] = useState<number | null>(base && base.startsAt > 0 ? base.startsAt : null);
  const [end, setEnd] = useState<number | null>(base && base.endsAt < NO_END ? base.endsAt : null);
  const [qualifier, setQualifier] = useState(String(base?.qualifierUsd ?? 20));
  const [exclude, setExclude] = useState((base?.exclude ?? []).join("\n"));
  const [testers, setTesters] = useState((base?.testers ?? []).join("\n"));
  const [busy, setBusy] = useState(false);
  const [checks, setChecks] = useState<Check[] | null>(null);
  const [resetId, setResetId] = useState("");
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => setNote(null), [id, terms, start, end, qualifier, exclude, testers]);

  const ex = parseAddresses(exclude);
  const ts = parseAddresses(testers);
  const draft: RaffleConfig = {
    id: id.trim(),
    terms: terms.trim().toLowerCase() as `0x${string}`,
    startsAt: start ?? 0,
    endsAt: end ?? NO_END,
    qualifierUsd: Number(qualifier),
    exclude: ex.ok,
    testers: ts.ok,
  };

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

  const selfTest = async () => {
    setChecks(null);
    const out: Check[] = [];
    const push = (label: string, ok: boolean | null, detail = "") => out.push({ label, ok, detail });
    const c = await api.config().catch(() => null);
    push("Admin token accepted", !!c, c ? `config source: ${c.source}` : "refused");
    const eff = c?.effective;
    push("A promotion is configured", !!eff, eff ? eff.id : c?.source === "disabled" ? "switched off" : "none");
    if (eff && c) {
      push("Inside its window", c.live, `${utc(eff.startsAt)} → ${utc(eff.endsAt)} · now ${utc(c.now)}`);
      push("Terms match this build's TC.md", eff.terms === buildTerms, eff.terms === buildTerms ? buildTerms : `worker ${eff.terms} ≠ build ${buildTerms} — every entry would be refused`);
      const pub = await api.publicSummary().catch(() => null);
      if (c.testMode) push("Hidden from the public (test mode)", pub?.live === false && !pub.promotion, pub?.live ? "the public sees it live!" : "visitors see no notice");
      else push("Visible to the public", pub?.live === true && pub.promotion === eff.id, pub?.live ? `${pub.entrants ?? 0} entrants` : "visitors see no notice");
      for (const t of eff.testers) {
        const s = await api.publicStatus(t).catch(() => null);
        push(`Tester ${t.slice(0, 8)}… sees the draw`, s?.live === true, s ? `${s.traded ? "has a fill → Participate shown" : "no fill yet → Participate locked"}${s.entered ? " · entered" : ""}` : "unreachable");
      }
    }
    try {
      const head = await rsk.getBlockNumber();
      push("Rootstock RPC (draw blocks)", true, `head ${head}`);
    } catch (e) {
      push("Rootstock RPC (draw blocks)", false, errorText(e));
    }
    setChecks(out);
  };

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">Configuration</span>
          <span className="lbl">
            source: <b>{config.source}</b>
          </span>
        </div>
        <div className="boxbody">
          <label className="pq">
            <span className="pqlabel">Promotion id</span>
            <input className="pqtext m" value={id} onChange={(e) => setId(e.target.value)} placeholder="rootstock-beta-1" />
            <span className="pqfine">Lower-case, digits, dashes. Entries are kept per id — rehearse under e.g. "rehearsal-1", then reset it.</span>
          </label>
          <label className="pq">
            <span className="pqlabel">Terms hash</span>
            <input className="pqtext m" value={terms} onChange={(e) => setTerms(e.target.value)} />
            <span className="pqfine">
              This build ships {buildTerms.slice(0, 10)}…{" "}
              {terms.toLowerCase() !== buildTerms && (
                <button type="button" className="linkbtn" onClick={() => setTerms(buildTerms)}>
                  use it
                </button>
              )}
            </span>
          </label>
          <ZoneSwitch zone={zone} onChange={setZone} />
          <div className="adrow adtimes">
            <DateTimeField
              label="Starts"
              hint="fills before this do not unlock Participate"
              value={start}
              onChange={setStart}
              zone={zone}
              empty="Open from the beginning (any fill counts)"
              presets={[
                { label: "Now", value: nowSec },
                { label: "Today 00:00", value: () => toUnix(fromUnix(nowSec(), zone).date, "00:00", zone) },
                { label: "Clear", value: () => null },
              ]}
            />
            <DateTimeField
              label="Entries close"
              value={end}
              onChange={setEnd}
              zone={zone}
              empty="No end"
              presets={[
                { label: "+1 day", value: () => (start ?? nowSec()) + DAY },
                { label: "+7 days", value: () => (start ?? nowSec()) + 7 * DAY },
                { label: "+10 days", value: () => (start ?? nowSec()) + 10 * DAY },
                { label: "Clear", value: () => null },
              ]}
            />
          </div>
          {start !== null && end !== null && end <= start && <p className="warn pqfine">Entries close before the start.</p>}
          <label className="pq adnarrow">
            <span className="pqlabel">Daily qualifier, $</span>
            <input className="pqtext m" inputMode="decimal" value={qualifier} onChange={(e) => setQualifier(e.target.value)} />
            <span className="pqfine">USD of maker fills in one UTC day to enter that day&rsquo;s draw. For a rehearsal, $1 keeps test swaps cheap.</span>
          </label>
          <label className="pq">
            <span className="pqlabel">
              Testers <span className="pqopt-tag">· any address here = TEST MODE: live only for these, invisible to everyone else</span>
            </span>
            <textarea className="pqtext m" rows={3} value={testers} onChange={(e) => setTesters(e.target.value)} placeholder="0x… one per line" />
            {ts.bad.length > 0 && <span className="warn pqfine">Not addresses: {ts.bad.join(", ")}</span>}
          </label>
          <label className="pq">
            <span className="pqlabel">
              Excluded from draws <span className="pqopt-tag">· team, contractors, ambassadors (TC §3.3); our fillers are always excluded</span>
            </span>
            <textarea className="pqtext m" rows={3} value={exclude} onChange={(e) => setExclude(e.target.value)} placeholder="0x… one per line" />
            {ex.bad.length > 0 && <span className="warn pqfine">Not addresses: {ex.bad.join(", ")}</span>}
          </label>
          {note && <p className="good pqfine">{note}</p>}
          <div className="adrow">
            <button type="button" className="cta" disabled={busy || ex.bad.length > 0 || ts.bad.length > 0 || (start !== null && end !== null && end <= start)} onClick={() => run(() => api.saveConfig(draft), "Saved — live on the orderbook now.")}>
              {ts.ok.length ? "Save (test mode)" : "Save (public)"}
            </button>
            <button type="button" className="cta line" disabled={busy || config.source === "disabled"} onClick={() => run(() => api.disable(), "Switched off: no notice, no entries.")}>
              Switch off
            </button>
            <button type="button" className="cta line" disabled={busy || config.source === "env" || !config.env} onClick={() => run(() => api.revertToEnv(), "Back to the deploy defaults (RAFFLE_*).")}>
              Use deploy defaults
            </button>
          </div>
          {config.env && (
            <p className="pqfine">
              Deploy defaults: {config.env.id} · {utc(config.env.startsAt)} → {utc(config.env.endsAt)}
            </p>
          )}
        </div>
      </section>

      <section className="box">
        <div className="boxhead">
          <span className="lbl">Tests</span>
        </div>
        <div className="boxbody">
          <p className="pqnote">
            Checks what the running configuration does for a visitor and for each tester. A full rehearsal: add your
            wallets as testers, trade once from each, press Participate in the app, then run a test draw under Draws —
            and reset the rehearsal promotion below.
          </p>
          <button type="button" className="cta line" onClick={selfTest}>
            Run checks
          </button>
          {checks && (
            <ul className="adchecks">
              {checks.map((c) => (
                <li key={c.label} className={c.ok ? "good" : c.ok === false ? "warn" : ""}>
                  <span>{c.ok ? "✓" : c.ok === false ? "✗" : "·"}</span> <b>{c.label}</b> <span className="pqfine">{c.detail}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      <section className="box addanger">
        <div className="boxhead">
          <span className="lbl">Reset &amp; cleanup</span>
        </div>
        <div className="boxbody">
          <label className="pq">
            <span className="pqlabel">Reset a promotion — deletes ALL its entries (feedback included) and draw records</span>
            <input className="pqtext m" value={resetId} onChange={(e) => setResetId(e.target.value)} placeholder="type the promotion id to confirm" />
          </label>
          <button
            type="button"
            className="cta line"
            disabled={busy || !resetId.trim()}
            onClick={() =>
              window.confirm(`Delete every entry and draw of "${resetId.trim()}"? This cannot be undone.`) &&
              run(async () => {
                const r = await api.reset(resetId.trim(), resetId.trim());
                setNote(`Reset ${resetId.trim()}: ${r.entriesRemoved} entries, ${r.drawsRemoved} draws removed.`);
                setResetId("");
              })
            }
          >
            Reset promotion
          </button>
          <p className="pqfine">After the last payout: delete the contact field of every entry of the selected promotion (TC §4.7).</p>
          <button
            type="button"
            className="cta line"
            disabled={busy || !config.effective}
            onClick={() =>
              window.confirm("Delete every contact detail of the running promotion?") &&
              run(async () => {
                const r = await api.purgeContacts();
                setNote(`${r.purged} contact detail(s) deleted.`);
              })
            }
          >
            Purge contacts (running promotion)
          </button>
        </div>
      </section>
    </div>
  );
}
