import { useEffect, useMemo, useRef } from "react";

// The promotion terms live in one file at the repository root, and the site
// renders that file rather than a copy of it. A second copy is a copy that
// drifts, and the one place that must not drift is the text people agreed to.
import source from "../../../../TC.md?raw";

import { renderMarkdown } from "../lib/markdown";

/** The line the document dates itself with — surfaced next to the Terms link. */
export const TERMS_UPDATED = (/\*\*Last updated:\*\*\s*(.+)/.exec(source)?.[1] ?? "").trim();

export function TermsDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  const body = useMemo(() => renderMarkdown(source), []);
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!open) return;
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    // The document is long; letting the page behind it scroll too makes the
    // wheel land on whichever layer happens to be under the pointer.
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="sheet" role="dialog" aria-modal="true" aria-label="Terms and Conditions">
        <div className="sheethead">
          <span className="lbl">Terms &amp; Conditions</span>
          <button ref={closeRef} type="button" className="iconbtn" onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>
        <div className="sheetbody md">{body}</div>
      </div>
    </div>
  );
}
