import { useMemo } from "react";

// The terms live in one file at the repository root, and the site renders that
// file rather than a copy of it. A second copy is a copy that drifts, and the
// one text that must not drift is the one people agreed to.
import source from "../../../../TC.md?raw";

import { useTheme } from "../hooks/useTheme";
import { renderMarkdown } from "../lib/markdown";

/**
 * The whole document, as its own page at its own URL rather than a dialog: the
 * terms get quoted in announcements and support replies, and a link has to
 * survive being pasted somewhere the app is not running.
 *
 * The document dates itself in its own first lines, so nothing here repeats it.
 */
export function TermsPage() {
  const [theme, toggleTheme] = useTheme();
  const body = useMemo(() => renderMarkdown(source), []);

  return (
    <>
      <div className="nav">
        <a className="brand" href="./">
          1delta X <em>Intents</em>
        </a>
        <div className="navspace" />
        <a className="netpill" href="./">
          ← Back to trading
        </a>
        <button
          type="button"
          className="iconbtn"
          onClick={toggleTheme}
          aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
        >
          {theme === "dark" ? "☀" : "☾"}
        </button>
      </div>

      <main className="reading">
        <article className="md">{body}</article>
      </main>

      <footer>
        <p>
          Questions about the draw go to <a href="mailto:team@1delta.io">team@1delta.io</a>.
        </p>
      </footer>
    </>
  );
}
