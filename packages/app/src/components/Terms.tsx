import { useMemo } from "react";

// The terms live in one file at the repository root, and the site renders that
// file rather than a copy of it. A second copy is a copy that drifts, and the
// one text that must not drift is the one people agreed to.
import source from "../../../../TC.md?raw";

import { useTheme } from "../hooks/useTheme";
import { t, tr, useLang } from "../i18n";
import { renderMarkdown } from "../lib/markdown";
import { LangSelect } from "./LangSelect";

/**
 * The whole document, as its own page at its own URL rather than a dialog: the
 * terms get quoted in announcements and support replies, and a link has to
 * survive being pasted somewhere the app is not running.
 *
 * The document dates itself in its own first lines, so nothing here repeats it.
 */
export function TermsPage() {
  const [theme, toggleTheme] = useTheme();
  const lang = useLang();
  // Back to the app in the language the reader is in.
  const home = lang === "en" ? "./" : `./?lang=${lang}`;
  const body = useMemo(() => renderMarkdown(source), []);

  return (
    <>
      <div className="nav">
        <a className="brand" href={home}>
          1delta X <em>Intents</em>
        </a>
        <div className="navspace" />
        <a className="netpill" href={home}>
          {t("← Back to trading")}
        </a>
        <LangSelect />
        <button
          type="button"
          className="iconbtn"
          onClick={toggleTheme}
          aria-label={theme === "dark" ? t("Switch to light theme") : t("Switch to dark theme")}
        >
          {theme === "dark" ? "☀" : "☾"}
        </button>
      </div>

      <main className="reading">
        {lang !== "en" && (
          <p className="capnote dim" role="note">
            {t("These terms exist in English only. The English text below is the one that applies.")}
          </p>
        )}
        <article className="md" lang="en">
          {body}
        </article>
      </main>

      <footer>
        <p>
          {tr("Questions about the draw go to <mail>team@1delta.io</mail>.", { mail: (c) => <a href="mailto:team@1delta.io">{c}</a> })}
        </p>
      </footer>
    </>
  );
}
