import { useCallback, useEffect, useMemo, useState } from "react";
import { isAddress } from "viem";

import { ORDERBOOK_URL } from "./config";
import { useTheme } from "@app/hooks/useTheme";
import { AdminApi, AdminError } from "./adminApi";
import { FeedbackTab } from "./tabs/FeedbackTab";
import { QualifiersTab } from "./tabs/QualifiersTab";
import { SupportTab } from "./tabs/SupportTab";

const TOKEN_KEY = "1delta-x.raffle-admin-token";

type Tab = "qualifiers" | "feedback" | "support";

export const utc = (sec: number | null | undefined) => (sec === null || sec === undefined ? "—" : new Date(sec * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC");
export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
export const parseAddresses = (text: string): { ok: string[]; bad: string[] } => {
  const parts = text.split(/[\s,;]+/).map((s) => s.trim()).filter(Boolean);
  return { ok: [...new Set(parts.filter((p) => isAddress(p, { strict: false })).map((p) => p.toLowerCase()))], bad: parts.filter((p) => !isAddress(p, { strict: false })) };
};
export function errorText(e: unknown): string {
  if (e instanceof AdminError && e.status === 403) return "The orderbook refused the admin token.";
  return e instanceof Error ? e.message.split("\n")[0]! : String(e);
}

/**
 * THE RAFFLE OPERATOR CONSOLE — deliberately small. The draw is stated as fixed copy in
 * the app and evaluated by hand (the Terms promise no registration and leave criteria,
 * timing and amounts to 1delta), so nothing here configures it. Three tabs: each UTC
 * day's addresses and volumes off the fill index (Qualifiers), the optional feedback
 * (Feedback), and a lookup / deletion desk (Support). The token is the orderbook
 * worker's `RAFFLE_ADMIN_TOKEN`; this page holds no secret of its own.
 */
export function AdminApp() {
  const [theme, toggleTheme] = useTheme();
  const [token, setToken] = useState(() => {
    try {
      return sessionStorage.getItem(TOKEN_KEY) ?? "";
    } catch {
      return "";
    }
  });
  const [draft, setDraft] = useState("");
  const [promotion, setPromotion] = useState<string | null>(null);
  const [feedbackCount, setFeedbackCount] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("qualifiers");

  const api = useMemo(() => (token && ORDERBOOK_URL ? new AdminApi(ORDERBOOK_URL, token) : null), [token]);

  // Sign-in check: the entries route needs the token; the summary tells us the form's key.
  const reload = useCallback(async () => {
    if (!api) return;
    try {
      const [s] = await Promise.all([api.summary(), api.entries()]);
      setPromotion(s.promotion ?? null);
      setFeedbackCount(s.feedback ?? 0);
      setError(null);
    } catch (e) {
      setError(errorText(e));
      if (e instanceof AdminError && e.status === 403) {
        setToken("");
        try {
          sessionStorage.removeItem(TOKEN_KEY);
        } catch {
          /* nothing stored */
        }
      }
    }
  }, [api]);

  useEffect(() => void reload(), [reload]);

  const signIn = () => {
    const t = draft.trim();
    if (!t) return;
    try {
      sessionStorage.setItem(TOKEN_KEY, t);
    } catch {
      /* the session only */
    }
    setToken(t);
    setDraft("");
  };
  const signOut = () => {
    try {
      sessionStorage.removeItem(TOKEN_KEY);
    } catch {
      /* nothing stored */
    }
    setToken("");
  };

  return (
    <>
      <div className="nav">
        <a className="brand" href="./">
          1delta X <em>Raffle admin</em>
        </a>
        <div className="navspace" />
        {token && promotion && (
          <span className="netpill" title="the feedback form's key on the orderbook">
            {promotion} · {feedbackCount ?? "…"} feedback
          </span>
        )}
        {token && (
          <button type="button" className="netpill" onClick={signOut}>
            Sign out
          </button>
        )}
        <button type="button" className="iconbtn" onClick={toggleTheme} aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}>
          {theme === "dark" ? "☀" : "☾"}
        </button>
      </div>
      <main className="admin">
        {!ORDERBOOK_URL ? (
          <p className="signerr">This build has no orderbook (VITE_ORDERBOOK_URL is unset).</p>
        ) : !token ? (
          <div className="box adlogin">
            <div className="boxhead">
              <span className="lbl">Admin token</span>
            </div>
            <div className="boxbody">
              <p className="pqnote">The orderbook worker&rsquo;s RAFFLE_ADMIN_TOKEN. Kept in this tab only (session storage).</p>
              <input className="pqtext m" type="password" autoComplete="off" value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => e.key === "Enter" && signIn()} />
              {error && <p className="signerr">{error}</p>}
              <button type="button" className="cta" disabled={!draft.trim()} onClick={signIn}>
                Open admin
              </button>
            </div>
          </div>
        ) : !api ? null : (
          <>
            <div className="adtabs" role="tablist">
              {(["qualifiers", "feedback", "support"] as const).map((t) => (
                <button key={t} type="button" role="tab" aria-selected={tab === t} className={`pqopt${tab === t ? " on" : ""}`} onClick={() => setTab(t)}>
                  {{ qualifiers: "Qualifiers", feedback: "Feedback", support: "Support" }[t]}
                </button>
              ))}
            </div>
            {error && <p className="signerr">{error}</p>}
            {tab === "qualifiers" && <QualifiersTab />}
            {tab === "feedback" && (promotion ? <FeedbackTab api={api} promotion={promotion} /> : <p className="pqnote">The orderbook keeps no feedback form (RAFFLE_ID is unset).</p>)}
            {tab === "support" && (promotion ? <SupportTab api={api} promotion={promotion} onChanged={reload} /> : <p className="pqnote">The orderbook keeps no feedback form (RAFFLE_ID is unset).</p>)}
          </>
        )}
      </main>
    </>
  );
}
