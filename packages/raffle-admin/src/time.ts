/**
 * Time zones for the console's date pickers. Everything is stored as unix seconds;
 * the operator types wall-clock time in the zone they pick:
 *
 *   UTC  — what the draw rules use (a draw day is a UTC day);
 *   CET  — Europe/Berlin, i.e. CET in winter and CEST in summer (DST handled);
 *   Local — the browser's own zone.
 *
 * No library: the zone offset at an instant comes from Intl, and wall time → instant
 * is solved by two offset lookups (the second settles the DST switch hours).
 */
export type Zone = "UTC" | "CET" | "Local";

export const ZONES: readonly Zone[] = ["UTC", "CET", "Local"];

export function ianaOf(zone: Zone): string {
  if (zone === "UTC") return "UTC";
  if (zone === "CET") return "Europe/Berlin";
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

interface Parts {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
}

function partsAt(ms: number, iana: string): Parts {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: iana,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
  const p = Object.fromEntries(f.formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  return { year: +p.year!, month: +p.month!, day: +p.day!, hour: +p.hour! % 24, minute: +p.minute! };
}

/** The zone's offset from UTC at `ms`, in ms (CEST → +2 h). */
export function offsetMs(ms: number, iana: string): number {
  const p = partsAt(ms, iana);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute) - Math.floor(ms / 60_000) * 60_000;
}

/** "2026-10-25" + "14:30" in `zone` → unix seconds; null for an unparseable input. */
export function toUnix(date: string, time: string, zone: Zone): number | null {
  const d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  const t = /^(\d{1,2}):(\d{2})$/.exec(time || "00:00");
  if (!d || !t) return null;
  const wall = Date.UTC(+d[1]!, +d[2]! - 1, +d[3]!, +t[1]!, +t[2]!);
  if (!Number.isFinite(wall)) return null;
  const iana = ianaOf(zone);
  let ms = wall - offsetMs(wall, iana);
  ms = wall - offsetMs(ms, iana);
  return Math.floor(ms / 1000);
}

/** Unix seconds → the wall-clock date and time in `zone`. */
export function fromUnix(sec: number, zone: Zone): { date: string; time: string } {
  const p = partsAt(sec * 1000, ianaOf(zone));
  const z = (n: number, w = 2) => String(n).padStart(w, "0");
  return { date: `${z(p.year, 4)}-${z(p.month)}-${z(p.day)}`, time: `${z(p.hour)}:${z(p.minute)}` };
}

/** "Tue 21 Oct 2026, 18:00 CEST" — the instant as seen in `zone`. */
export function describe(sec: number, zone: Zone): string {
  const iana = ianaOf(zone);
  const s = new Intl.DateTimeFormat("en-GB", {
    timeZone: iana,
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZoneName: "short",
  }).format(new Date(sec * 1000));
  // en-GB names Berlin "CET"/"CEST" but UTC "UTC"; keep whatever Intl says.
  return s.replace(" at ", ", ");
}
