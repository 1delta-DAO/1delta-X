import { useState } from "react";

import { useDismiss } from "../hooks/useDismiss";
import { LANGS, setLang, t, useLang } from "../i18n";

/**
 * The language, which lives in the URL (`?lang=es`): picking one rewrites the query
 * in place, so the choice can be linked and a reload keeps it.
 */
export function LangSelect() {
  const [open, setOpen] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));
  const lang = useLang();
  return (
    <div className="menu" ref={ref}>
      <button
        type="button"
        className="netpill"
        aria-haspopup="true"
        aria-expanded={open}
        aria-label={t("Language")}
        title={t("Language")}
        onClick={() => setOpen((o) => !o)}
      >
        {LANGS.find((l) => l.id === lang)?.short}
        <span className="car">▼</span>
      </button>
      {open && (
        <div className="dropdown" role="menu">
          {LANGS.map((l) => (
            <button
              key={l.id}
              type="button"
              role="menuitem"
              lang={l.id}
              aria-selected={l.id === lang}
              onClick={() => {
                setOpen(false);
                setLang(l.id);
              }}
            >
              {l.name}
              <span className="b2">{l.short}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
