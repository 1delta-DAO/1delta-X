import { useCallback, useEffect, useMemo, useState } from "react";
import { createPublicClient, http, isAddress } from "viem";
import { rootstock } from "viem/chains";

import { ORDERBOOK_URL, TERMS_HASH } from "./config";
import { useTheme } from "@app/hooks/useTheme";
import { AdminApi, AdminError, NO_END, type AdminConfig } from "./adminApi";
import { DrawsTab } from "./tabs/DrawsTab";
import { FeedbackTab } from "./tabs/FeedbackTab";
import { SetupTab } from "./tabs/SetupTab";
import { SupportTab } from "./tabs/SupportTab";

const TOKEN_KEY = "1delta-x.raffle-admin-token";
export const rsk = createPublicClient({ chain: rootstock, transport: http(undefined, { retryCount: 1, timeout: 15_000 }) });

type Tab = "setup" | "feedback" | "support" | "draws";

export const utc = (sec: number | null | undefined) =>
  sec === null || sec === undefined ? "—" : sec >= NO_END ? "no end" : new Date(sec * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
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
 * THE RAFFLE ADMIN PAGE (admin.html). Configure the draw, rehearse it in test mode,
 * read the feedback, handle support cases, run the daily draws, and reset after a
 * rehearsal. Every action is an `/raffle/admin/*` call the orderbook worker authorises
 * with `RAFFLE_ADMIN_TOKEN`; this page holds no secret of its own and is useless
 * without the token.
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
  const [config, setConfig] = useState<AdminConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("setup");
  // The promotion the Feedback / Support / Draws tabs look at: the running one by default.
  const [promotion, setPromotion] = useState<string | null>(null);

  const api = useMemo(() => (token && ORDERBOOK_URL ? new AdminApi(ORDERBOOK_URL, token) : null), [token]);

  const reload = useCallback(async () => {
    if (!api) return;
    try {
      setConfig(await api.config());
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
    setConfig(null);
  };

  const active = promotion ?? config?.effective?.id ?? null;

  return (
    <>
      <div className="nav">
        <a className="brand" href="./">
          1delta X <em>Raffle admin</em>
        </a>
        <div className="navspace" />
        {config && (
          <span className="netpill" title="effective configuration">
            {config.effective ? `${config.effective.id} · ${config.live ? (config.testMode ? "TEST MODE" : "LIVE") : "closed"}` : config.source === "disabled" ? "switched off" : "no draw"}
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
        ) : !config || !api ? (
          <p className="pqnote">{error ?? "Loading…"}</p>
        ) : (
          <>
            <div className="adtabs" role="tablist">
              {(["setup", "feedback", "support", "draws"] as const).map((t) => (
                <button key={t} type="button" role="tab" aria-selected={tab === t} className={`pqopt${tab === t ? " on" : ""}`} onClick={() => setTab(t)}>
                  {{ setup: "Setup & tests", feedback: "Feedback", support: "Support", draws: "Draws" }[t]}
                </button>
              ))}
              <span className="navspace" />
              <PromotionPicker api={api} value={active} onChange={setPromotion} running={config.effective?.id ?? null} />
            </div>
            {error && <p className="signerr">{error}</p>}
            {tab === "setup" && <SetupTab api={api} config={config} buildTerms={TERMS_HASH} onChanged={reload} onError={setError} />}
            {tab === "feedback" && active && <FeedbackTab api={api} promotion={active} />}
            {tab === "support" && active && <SupportTab api={api} promotion={active} config={config} />}
            {tab === "draws" && active && <DrawsTab api={api} promotion={active} config={config} />}
            {tab !== "setup" && !active && <p className="pqnote">No promotion yet — configure one under Setup.</p>}
          </>
        )}
      </main>
    </>
  );
}

function PromotionPicker({ api, value, onChange, running }: { api: AdminApi; value: string | null; onChange: (p: string | null) => void; running: string | null }) {
  const [ids, setIds] = useState<string[]>([]);
  useEffect(() => {
    void api
      .promotions()
      .then((r) => setIds(r.promotions.map((p) => p.promotion)))
      .catch(() => {});
  }, [api, value]);
  const all = [...new Set([...(running ? [running] : []), ...ids, ...(value ? [value] : [])])];
  if (all.length === 0) return null;
  return (
    <label className="adpick">
      <span className="lbl">Promotion</span>
      <select className="pqtext m" value={value ?? ""} onChange={(e) => onChange(e.target.value === running ? null : e.target.value)}>
        {all.map((id) => (
          <option key={id} value={id}>
            {id}
            {id === running ? " (running)" : ""}
          </option>
        ))}
      </select>
    </label>
  );
}
