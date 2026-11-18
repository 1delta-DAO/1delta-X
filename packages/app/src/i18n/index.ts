import { createElement, Fragment, useSyncExternalStore, type ReactNode } from "react";

import { ES } from "./es";

/**
 * Two languages, gettext style: the ENGLISH sentence is the key.
 *
 *   t("Switch to {chain}", { chain })          a string
 *   tr("Signing is <b>free</b>", { b: … })     a sentence with markup in it
 *   msg("Market")                              marks a constant translated later, by t(x.label)
 *
 * English stays in the source where it is read and reviewed, and a missing
 * translation falls back to it instead of showing a key. `test/i18n.test.ts`
 * scans the sources for these calls and fails on an untranslated string, a
 * stale dictionary entry, or a translation whose placeholders differ.
 *
 * The language is part of the URL, as a query parameter (`?lang=es`) on every
 * page. Nothing is stored, so a link always opens in the language it was copied in.
 */
export type Lang = "en" | "es";

export const LANGS: ReadonlyArray<{ id: Lang; short: string; name: string }> = [
  { id: "en", short: "EN", name: "English" },
  { id: "es", short: "ES", name: "Español" },
];

const DICTIONARIES: Record<Exclude<Lang, "en">, Record<string, string>> = { es: ES };

function isLang(s: string | null | undefined): s is Lang {
  return LANGS.some((l) => l.id === s);
}

/** The language a URL's query names (`?lang=es`); English otherwise. */
export function langOfSearch(search: string): Lang {
  const param = new URLSearchParams(search).get("lang");
  return isLang(param) ? param : "en";
}

/** `search` with its `lang` parameter set to `lang` (removed for English), every other parameter kept. */
export function searchForLang(search: string, lang: Lang): string {
  const params = new URLSearchParams(search);
  if (lang === "en") params.delete("lang");
  else params.set("lang", lang);
  const out = params.toString();
  return out ? `?${out}` : "";
}

let current: Lang = typeof location === "undefined" ? "en" : langOfSearch(location.search);
const listeners = new Set<() => void>();

function apply(lang: Lang) {
  if (lang === current) return;
  current = lang;
  if (typeof document !== "undefined") document.documentElement.lang = lang;
  for (const l of listeners) l();
}

if (typeof document !== "undefined") document.documentElement.lang = current;
// Back / forward across a language switch.
if (typeof window !== "undefined") {
  window.addEventListener("popstate", () => apply(langOfSearch(location.search)));
}

export function getLang(): Lang {
  return current;
}

/** Switch language in place (no reload: the ticket, the wallet and the feeds stay as they are). */
export function setLang(lang: Lang) {
  if (typeof history !== "undefined" && typeof location !== "undefined") {
    history.pushState(null, "", `${location.pathname}${searchForLang(location.search, lang)}${location.hash}`);
  }
  apply(lang);
}

/** Tests only: set the language without touching a URL. */
export function setLangForTest(lang: Lang) {
  apply(lang);
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/**
 * The current language, re-rendering the caller when it changes. The page roots
 * call it, which re-renders everything below them; a component needs it itself
 * only to put the language in a `useMemo` / `useEffect` dependency list.
 */
export function useLang(): Lang {
  return useSyncExternalStore(subscribe, getLang, () => "en" as Lang);
}

export type Vars = Record<string, string | number>;

function lookup(en: string): string {
  return current === "en" ? en : (DICTIONARIES[current][en] ?? en);
}

/** `en` in the current language, with `{name}` placeholders filled from `vars`. */
export function t(en: string, vars?: Vars): string {
  const s = lookup(en);
  return vars ? s.replace(/\{(\w+)\}/g, (whole, name: string) => (name in vars ? String(vars[name]) : whole)) : s;
}

/** Marks a string for translation where it is DEFINED (a module constant); translate it where it is shown: `t(x.label)`. */
export function msg(en: string): string {
  return en;
}

type RichVars = Record<string, ReactNode | ((children: ReactNode) => ReactNode)>;

/**
 * A sentence with markup or components inside it, kept whole so a translation can
 * reorder it: `{name}` is replaced by a node, `<name>text</name>` by
 * `vars.name(text)`. Tags do not nest.
 */
export function tr(en: string, vars: RichVars): ReactNode {
  const out: ReactNode[] = [];
  const pattern = /\{(\w+)\}|<(\w+)>(.*?)<\/\2>/gs;
  const s = lookup(en);
  let at = 0;
  for (const m of s.matchAll(pattern)) {
    const index = m.index ?? 0;
    if (index > at) out.push(s.slice(at, index));
    const [whole, name, tag, inner] = m;
    if (name !== undefined) {
      const v = vars[name];
      out.push(v === undefined ? whole : typeof v === "function" ? v(null) : v);
    } else {
      const v = tag !== undefined ? vars[tag] : undefined;
      out.push(typeof v === "function" ? v(inner) : (inner ?? ""));
    }
    at = index + whole.length;
  }
  if (at < s.length) out.push(s.slice(at));
  // Spread as children (not an array child), so the pieces need no keys.
  return createElement(Fragment, null, ...out);
}
