import { useEffect, useState } from "react";

import { describe, fromUnix, toUnix, ZONES, type Zone } from "./time";

const ZONE_KEY = "1delta-x.raffle-admin.zone";

/** The zone the operator types times in, remembered per browser (CET by default). */
export function useZone(): [Zone, (z: Zone) => void] {
  const [zone, setZone] = useState<Zone>(() => {
    try {
      const z = localStorage.getItem(ZONE_KEY) as Zone | null;
      return z && ZONES.includes(z) ? z : "CET";
    } catch {
      return "CET";
    }
  });
  const set = (z: Zone) => {
    setZone(z);
    try {
      localStorage.setItem(ZONE_KEY, z);
    } catch {
      /* this tab only */
    }
  };
  return [zone, set];
}

export function ZoneSwitch({ zone, onChange }: { zone: Zone; onChange: (z: Zone) => void }) {
  return (
    <span className="adzone" role="radiogroup" aria-label="Time zone">
      <span className="pqfine">Times in</span>
      {ZONES.map((z) => (
        <button key={z} type="button" role="radio" aria-checked={zone === z} className={`pqopt${zone === z ? " on" : ""}`} onClick={() => onChange(z)}>
          {z === "CET" ? "CET/CEST" : z}
        </button>
      ))}
    </span>
  );
}

export interface Preset {
  label: string;
  /** Unix seconds, or null to clear. */
  value: () => number | null;
}

/**
 * A date + 24-hour time in the chosen zone, stored as unix seconds. The line under it
 * spells the instant out in the chosen zone AND in UTC (the zone the draw days use),
 * so nobody has to work out an offset in their head.
 */
export function DateTimeField({
  label,
  hint,
  value,
  onChange,
  zone,
  empty,
  presets = [],
  defaultTime = "00:00",
  warnIfPast = false,
}: {
  label: string;
  hint?: string;
  value: number | null;
  onChange: (sec: number | null) => void;
  zone: Zone;
  /** What an empty field means ("open from the start", "no end"). */
  empty: string;
  presets?: Preset[];
  /** The time a date picked without one gets (an end date: 23:59, so the day is included). */
  defaultTime?: string;
  /** Flag an instant that has already passed (an end time). */
  warnIfPast?: boolean;
}) {
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [bad, setBad] = useState(false);

  // Re-render the stored instant whenever it or the zone changes.
  useEffect(() => {
    if (value === null) {
      setDate("");
      setTime("");
    } else {
      const w = fromUnix(value, zone);
      setDate(w.date);
      setTime(w.time);
    }
    setBad(false);
  }, [value, zone]);

  const commit = (d: string, t: string) => {
    if (!d) {
      setBad(false);
      onChange(null);
      return;
    }
    const tt = t.trim() || defaultTime;
    const sec = /^\d{1,2}:\d{2}$/.test(tt) && Number(tt.split(":")[0]) < 24 && Number(tt.split(":")[1]) < 60 ? toUnix(d, tt, zone) : null;
    setBad(sec === null);
    if (sec !== null) onChange(sec);
  };

  return (
    <div className="pq">
      <span className="pqlabel">
        {label} {hint && <span className="pqopt-tag">· {hint}</span>}
      </span>
      <div className="addt">
        <input className="pqtext m" type="date" value={date} onChange={(e) => (setDate(e.target.value), commit(e.target.value, time))} aria-label={`${label} date`} />
        <input
          className="pqtext m addttime"
          inputMode="numeric"
          placeholder="HH:MM"
          maxLength={5}
          value={time}
          onChange={(e) => setTime(e.target.value.replace(/[^0-9:]/g, ""))}
          onBlur={() => commit(date, time)}
          onKeyDown={(e) => e.key === "Enter" && commit(date, time)}
          aria-label={`${label} time (24 h)`}
        />
        <span className="addtzone m">{zone === "CET" ? "CET/CEST" : zone}</span>
      </div>
      {warnIfPast && value !== null && value <= Date.now() / 1000 && <span className="warn pqfine">This is in the past — the raffle would be closed.</span>}
      <span className={bad ? "warn pqfine" : "pqfine"}>
        {bad ? "Time must be 24-hour HH:MM" : value === null ? empty : zone === "UTC" ? describe(value, "UTC") : `${describe(value, zone)}  ·  ${describe(value, "UTC")}`}
      </span>
      {presets.length > 0 && (
        <span className="addtpresets">
          {presets.map((p) => (
            <button key={p.label} type="button" className="linkbtn" onClick={() => onChange(p.value())}>
              {p.label}
            </button>
          ))}
        </span>
      )}
    </div>
  );
}
