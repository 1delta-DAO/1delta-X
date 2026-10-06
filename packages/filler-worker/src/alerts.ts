import { sanitize } from "@1delta-x/beta-filler/core";

import type { AlertConfig } from "./config";

/** The alerter's durable state (kept in the DO with the worker state). */
export interface AlertState {
  /** Last time each alert key was SENT, ms. */
  lastSent: Record<string, number>;
  /** Send times in the last hour (global rate limit). */
  sentTimes: number[];
  /** Most recent alerts (sent or suppressed), newest last. */
  log: Array<{ at: number; key: string; text: string; delivered: boolean; suppressed?: string }>;
}

export const emptyAlertState = (): AlertState => ({ lastSent: {}, sentTimes: [], log: [] });

/**
 * The webhook body. Slack incoming webhooks take `{"text": …}`; Telegram's
 * `sendMessage` (ALERT_WEBHOOK_URL = https://api.telegram.org/bot<token>/sendMessage)
 * takes `{"chat_id": …, "text": …}`.
 */
export function alertBody(cfg: Pick<AlertConfig, "format" | "telegramChatId" | "name">, text: string): Record<string, unknown> {
  const line = `[${cfg.name}] ${text}`;
  if (cfg.format === "telegram") return { chat_id: cfg.telegramChatId ?? "", text: line, disable_web_page_preview: true };
  return { text: line };
}

/**
 * De-duplicated, rate-limited alerts: a key fires at most once per
 * ALERT_COOLDOWN_SECONDS, and at most ALERT_MAX_PER_HOUR alerts go out per hour in
 * total. Without ALERT_WEBHOOK_URL alerts are only logged (and listed in /status).
 */
export class Alerter {
  constructor(
    private readonly cfg: AlertConfig,
    readonly state: AlertState,
    private readonly doFetch: (url: string, init: RequestInit) => Promise<Response>,
    private readonly log: (m: string) => void,
    /** The webhook call is aborted after this long: a hanging webhook must not hold the tick. */
    private readonly timeoutMs = 5_000,
  ) {}

  /** @returns whether the alert was delivered to the webhook. */
  async raise(key: string, text: string, now: number): Promise<boolean> {
    const s = this.state;
    const clean = sanitize(text, 500);
    const last = s.lastSent[key];
    if (last !== undefined && now - last < this.cfg.cooldownMs) return false; // de-duplicated: no log spam either
    s.sentTimes = s.sentTimes.filter((t) => now - t < 3_600_000);
    const record = (delivered: boolean, suppressed?: string) => {
      s.log.push({ at: now, key, text: clean, delivered, ...(suppressed ? { suppressed } : {}) });
      if (s.log.length > 50) s.log.splice(0, s.log.length - 50);
    };
    for (const [k, t] of Object.entries(s.lastSent)) if (now - t > Math.max(this.cfg.cooldownMs, 86_400_000)) delete s.lastSent[k];
    if (s.sentTimes.length >= this.cfg.maxPerHour) {
      // NOT stamped into `lastSent` (review 2026-10-05): a key first raised while
      // the hourly cap is saturated would otherwise be silenced for a whole
      // cooldown after the cap clears — on an unattended filler the webhook is
      // the only eye, and `low:RBTC` first firing during an RPC brownout is
      // exactly the alert that must not be lost.
      this.log(`ALERT (rate-limited) ${key}: ${clean}`);
      record(false, "rate limit");
      return false;
    }
    s.lastSent[key] = now;
    s.sentTimes.push(now);
    this.log(`ALERT ${key}: ${clean}`);
    if (!this.cfg.webhookUrl) {
      record(false, "no ALERT_WEBHOOK_URL");
      return false;
    }
    try {
      const res = await this.doFetch(this.cfg.webhookUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(alertBody(this.cfg, clean)),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      record(res.ok, res.ok ? undefined : `webhook HTTP ${res.status}`);
      return res.ok;
    } catch (e) {
      record(false, `webhook: ${sanitize(e instanceof Error ? e.message : e, 100)}`);
      return false;
    }
  }
}
