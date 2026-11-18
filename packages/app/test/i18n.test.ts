import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it } from "vitest";

import { langOfSearch, searchForLang, setLangForTest, t, tr } from "../src/i18n";
import { ES, ES_FRAGMENTS } from "../src/i18n/es";

const SRC = join(__dirname, "..", "src");

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "i18n" ? [] : sources(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

/** Every string literal handed to t() / tr() / msg() in the app's sources. */
function usedKeys(): Map<string, string> {
  const call = /(?<![\w.])(?:t|tr|msg)\(\s*("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\$]|\\.)*`)/g;
  const keys = new Map<string, string>();
  for (const file of sources(SRC)) {
    for (const m of readFileSync(file, "utf8").matchAll(call)) {
      // The literal is TypeScript source: evaluate its escapes the way the compiler does.
      const key = new Function(`return ${m[1]};`)() as string;
      keys.set(key, file.slice(SRC.length + 1));
    }
  }
  return keys;
}

const shape = (s: string) => [...s.matchAll(/\{\w+\}|<\/?\w+>/g)].map((m) => m[0]).sort().join(" ");

describe("Spanish dictionary", () => {
  const used = usedKeys();

  it("the scan finds the app's strings", () => {
    expect(used.size).toBeGreaterThan(100);
  });

  it("translates every string the app shows", () => {
    const missing = [...used].filter(([k]) => !(k in ES)).map(([k, file]) => `${file}: ${k}`);
    expect(missing).toEqual([]);
  });

  it("holds no entry the app no longer uses", () => {
    expect(Object.keys(ES).filter((k) => !used.has(k))).toEqual([]);
  });

  it("keeps every placeholder and tag of the English sentence", () => {
    const bad = Object.entries(ES).filter(([en, es]) => shape(en) !== shape(es)).map(([en]) => en);
    expect(bad).toEqual([]);
  });

  it("reads the same wherever a sentence appears twice", () => {
    const seen = new Map<string, string>();
    const clash: string[] = [];
    for (const fragment of Object.values(ES_FRAGMENTS)) {
      for (const [en, es] of Object.entries(fragment)) {
        if (seen.has(en) && seen.get(en) !== es) clash.push(en);
        seen.set(en, es);
      }
    }
    expect(clash).toEqual([]);
  });

  it("uses no em dash and leaves nothing empty (app copy rule)", () => {
    expect(Object.entries(ES).filter(([, es]) => es.includes("—") || es.trim() === "").map(([en]) => en)).toEqual([]);
  });
});

describe("language routing", () => {
  afterEach(() => setLangForTest("en"));

  it("reads the language from ?lang=", () => {
    expect(langOfSearch("")).toBe("en");
    expect(langOfSearch("?lang=es")).toBe("es");
    expect(langOfSearch("?x=1&lang=es")).toBe("es");
    expect(langOfSearch("?lang=xx")).toBe("en");
  });

  it("sets the lang parameter and keeps the others", () => {
    expect(searchForLang("", "es")).toBe("?lang=es");
    expect(searchForLang("?lang=es", "en")).toBe("");
    expect(searchForLang("?x=1", "es")).toBe("?x=1&lang=es");
    expect(searchForLang("?x=1&lang=es", "en")).toBe("?x=1");
  });

  it("falls back to English, and fills placeholders in both languages", () => {
    expect(t("Switch to {chain}", { chain: "Rootstock" })).toBe("Switch to Rootstock");
    expect(t("a sentence nobody translated")).toBe("a sentence nobody translated");
    setLangForTest("es");
    expect(t("Switch to {chain}", { chain: "Rootstock" })).toBe(ES["Switch to {chain}"]!.replace("{chain}", "Rootstock"));
    expect(t("a sentence nobody translated")).toBe("a sentence nobody translated");
  });

  it("renders a sentence with markup in it, in the order the translation puts it", () => {
    const en = "no Settlement deployed on {chain}: signatures are real but <b>not fillable</b>";
    const render = () => renderToStaticMarkup(tr(en, { chain: "Rootstock", b: (c) => createElement("b", null, c) }) as never);
    expect(render()).toBe("no Settlement deployed on Rootstock: signatures are real but <b>not fillable</b>");
    setLangForTest("es");
    expect(render()).toBe(ES[en]!.replace("{chain}", "Rootstock"));
  });
});
