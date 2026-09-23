import { useCallback, useEffect, useState } from "react";

import { PROMOTION } from "../config/promotion";

/**
 * Bump when the disclosure itself changes — everyone acknowledges the new text
 * rather than inheriting consent to a version they never saw.
 */
const ACK_VERSION = "2026-09-beta-1";
const ACK_KEY = "1delta-x.preaudit";

export function useAcknowledgement() {
  const [acknowledged, setAcknowledged] = useState(() => {
    try {
      return localStorage.getItem(ACK_KEY) === ACK_VERSION;
    } catch {
      // Private-mode or blocked storage: show the disclosure every visit rather
      // than treat an unreadable store as consent.
      return false;
    }
  });

  const accept = useCallback(() => {
    try {
      localStorage.setItem(ACK_KEY, ACK_VERSION);
    } catch {
      // Not recording it only costs another prompt next visit.
    }
    setAcknowledged(true);
  }, []);

  return { acknowledged, accept };
}

/**
 * The strip that stays for the whole session, once the gate is behind you.
 *
 * It links back to the risk disclosure and to nothing else. The prize draw has
 * terms of its own, but they are a marketing document, and putting them here
 * would say that the audit status and the draw are one subject — which is the
 * conflation this strip exists to avoid. The draw carries its own link.
 */
export function PreAuditStrip({ onDetails }: { onDetails: () => void }) {
  return (
    <div className="preaudit" role="note">
      <span className="pill pill-orange">Pre-audit beta</span>
      <span>
        These contracts are <b>unaudited</b>. Approvals are limited to the amount of each order. Trade only what
        you can afford to lose.
      </span>
      <button type="button" className="linkbtn" onClick={onDetails}>
        What this means
      </button>
    </div>
  );
}

/**
 * The risk disclosure. On a first visit it has to be accepted before the app;
 * afterwards the strip reopens it read-only, because a disclosure you can only
 * ever see once is one you cannot check back on.
 */
export function PreAuditGate({
  review,
  onAccept,
  onClose,
  onTerms,
}: {
  /** True when this is a re-read rather than the gate. */
  review: boolean;
  onAccept: () => void;
  onClose: () => void;
  onTerms: () => void;
}) {
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    if (!review) return () => {
      document.body.style.overflow = previous;
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [review, onClose]);

  return (
    <div
      className="scrim"
      onMouseDown={(e) => review && e.target === e.currentTarget && onClose()}
    >
      <div className="sheet narrow" role="dialog" aria-modal="true" aria-labelledby="preaudit-title">
        <div className="sheethead">
          <span className="lbl">{review ? "Risk disclosure" : "Before you trade"}</span>
          {review && (
            <button type="button" className="iconbtn" onClick={onClose} aria-label="Close">
              ✕
            </button>
          )}
        </div>
        <div className="sheetbody">
          <h2 id="preaudit-title" className="gatetitle">
            This is an <span className="hl hl-orange">unaudited</span> pre-audit beta.
          </h2>
          <ul className="gatelist">
            <li>
              The settlement contracts have <b>not been audited</b>. They may contain bugs that cause you to lose
              the funds you trade or approve.
            </li>
            <li>
              Token approvals are capped at the exact amount of the order you are signing, so no standing
              allowance is left behind. This bounds the risk — it does not remove it.
            </li>
            <li>
              Orders are signed messages. A filler can settle any order you have signed that has not expired or
              been cancelled.
            </li>
            {/* With no draw running, describing one is not a disclosure —
                it is an advertisement for something that does not exist. */}
            {PROMOTION.live && (
            <li>
              Trading can qualify your address for a <b>random prize draw</b>. Qualifying does not earn a prize and
              no amount of volume guarantees one. The{" "}
              <button type="button" className="linkbtn" onClick={onTerms}>
                Terms &amp; Conditions
              </button>{" "}
              exclude U.S. Persons and sanctioned jurisdictions, and USDRIF carries its own transfer restrictions.
            </li>
            )}
            <li>Nothing here is financial, investment, legal or tax advice.</li>
          </ul>
          {review ? (
            <button type="button" className="cta" onClick={onClose}>
              Close
            </button>
          ) : (
            <>
              <label className="check">
                <input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
                <span>
                  I understand the contracts are unaudited, I accept the risk of total loss, and I agree to the
                  Terms &amp; Conditions.
                </span>
              </label>
              <button type="button" className="cta" disabled={!checked} onClick={onAccept}>
                Continue
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
