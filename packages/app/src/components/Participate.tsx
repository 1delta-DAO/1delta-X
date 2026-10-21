import { useEffect, useMemo, useState } from "react";
import { PARTICIPATION_QUESTIONS, validateAnswers, type ParticipationAnswers, type Question } from "@1delta-x/sdk";
import type { Address } from "viem";

import { submitParticipation, type TypedDataSigner } from "../lib/raffle";

/**
 * The FEEDBACK sheet: the rating questions, signed (gasless) as one EIP-712 message so
 * the answers provably come from a wallet that used the app. It is optional and is
 * NOT an entry: the Terms (§4.1) promise no registration, every trader is in the draw.
 */

export function ParticipateSheet({
  base,
  signer,
  chainId,
  participant,
  promotion,
  updating,
  onClose,
  onEntered,
  onSwitch,
}: {
  base: string;
  /** Null while the wallet is not on the draw's chain (EIP-712 signs the chain id). */
  signer: TypedDataSigner | null;
  chainId: number;
  participant: Address;
  promotion: string;
  /** Feedback already on file: this replaces the answers. */
  updating: boolean;
  /** The wallet is on another network: the sign button asks to switch instead (2026-10-21). */
  onSwitch?: () => void;
  onClose: () => void;
  onEntered: () => void;
}) {
  const [answers, setAnswers] = useState<ParticipationAnswers>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  useEffect(() => {
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && !busy && onClose();
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [busy, onClose]);

  const problem = useMemo(() => validateAnswers(answers), [answers]);
  const set = (id: string, v: string | readonly string[] | number | undefined) =>
    setAnswers((a) => {
      const next = { ...a };
      if (v === undefined || v === "" || (Array.isArray(v) && v.length === 0)) delete next[id];
      else next[id] = v;
      return next;
    });

  const submit = async () => {
    if (!signer || problem) return;
    setBusy(true);
    setError(null);
    try {
      await submitParticipation({ base, signer, chainId, participant, promotion, answers });
      setDone(true);
      onEntered();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setError(/rejected|denied/i.test(msg) ? "You declined the signature. Nothing was sent." : msg.split("\n")[0]!);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="scrim" onMouseDown={(e) => !busy && e.target === e.currentTarget && onClose()}>
      <div className="sheet" role="dialog" aria-modal="true" aria-labelledby="participate-title">
        <div className="sheethead">
          <span className="lbl">Feedback</span>
          <button type="button" className="iconbtn" onClick={onClose} aria-label="Close" disabled={busy}>
            ✕
          </button>
        </div>
        <div className="sheetbody">
          {done ? (
            <>
              <h2 id="participate-title" className="gatetitle">
                Thank you. <span className="hl hl-violet">Noted.</span>
              </h2>
              <p className="pqnote">
                Your answers are on file for this wallet. You can update them from the notice at any time. The draw itself
                needs nothing from you: every day you trade the qualifying amount is a ticket.
              </p>
              <button type="button" className="cta" onClick={onClose}>
                Close
              </button>
            </>
          ) : (
            <>
              <h2 id="participate-title" className="gatetitle">
                {updating ? "Update your answers" : "One minute of feedback"}
              </h2>
              <p className="pqnote">
                Your answers shape what we fix before the audited launch. Signing is free: it is a message, not a
                transaction. This is optional and changes nothing about the prize draw.
              </p>
              {PARTICIPATION_QUESTIONS.map((q) => (
                <QuestionField key={q.id} q={q} value={answers[q.id]} onChange={(v) => set(q.id, v)} />
              ))}
              <p className="pqfine">
                Stored with your address: your answers, the signature and the time. Nothing personal. Answers are
                never published.
              </p>
              {error && <p className="signerr">{error}</p>}
              {!signer && onSwitch ? (
                <button type="button" className="cta" onClick={onSwitch}>
                  Switch to Rootstock
                </button>
              ) : (
                <button type="button" className="cta" disabled={!signer || !!problem || busy} onClick={submit}>
                  {busy ? "Waiting for your wallet…" : updating ? "Sign & update" : "Sign & send feedback"}
                </button>
              )}
              {problem && Object.keys(answers).length > 0 && <p className="pqfine">{problem}</p>}
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function QuestionField({ q, value, onChange }: { q: Question; value: ParticipationAnswers[string] | undefined; onChange: (v: string | readonly string[] | number | undefined) => void }) {
  const label = (
    <legend className="pqlabel">
      {q.label}
      {!q.required && <span className="pqopt-tag"> · optional</span>}
    </legend>
  );
  switch (q.kind) {
    case "choice":
      return (
        <fieldset className="pq">
          {label}
          <div className="pqopts">
            {q.options.map((o) => (
              <button key={o} type="button" className={`pqopt${value === o ? " on" : ""}`} aria-pressed={value === o} onClick={() => onChange(value === o ? undefined : o)}>
                {o}
              </button>
            ))}
          </div>
        </fieldset>
      );
    case "multi": {
      const list = (Array.isArray(value) ? value : []) as readonly string[];
      return (
        <fieldset className="pq">
          {label}
          <div className="pqopts">
            {q.options.map((o) => {
              const on = list.includes(o);
              return (
                <button key={o} type="button" className={`pqopt${on ? " on" : ""}`} aria-pressed={on} onClick={() => onChange(on ? list.filter((x) => x !== o) : [...list, o])}>
                  {o}
                </button>
              );
            })}
          </div>
        </fieldset>
      );
    }
    case "scale":
      return (
        <fieldset className="pq">
          {label}
          <div className="pqscale">
            <span className="pqend">{q.low}</span>
            {[1, 2, 3, 4, 5].map((n) => (
              <button key={n} type="button" className={`pqopt m${value === n ? " on" : ""}`} aria-pressed={value === n} onClick={() => onChange(n)}>
                {n}
              </button>
            ))}
            <span className="pqend">{q.high}</span>
          </div>
        </fieldset>
      );
    case "text": {
      const text = typeof value === "string" ? value : "";
      return (
        <fieldset className="pq">
          {label}
          {q.max > 200 ? (
            <textarea className="pqtext" rows={3} maxLength={q.max} value={text} onChange={(e) => onChange(e.target.value)} onBlur={(e) => onChange(e.target.value.trim())} />
          ) : (
            <input className="pqtext" maxLength={q.max} value={text} onChange={(e) => onChange(e.target.value)} onBlur={(e) => onChange(e.target.value.trim())} autoComplete="off" />
          )}
        </fieldset>
      );
    }
  }
}
