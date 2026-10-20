#!/usr/bin/env bash
# One-shot setup of what the raffle operator console needs on Cloudflare. It is
# idempotent: anything already present is left alone.
#
#   make raffle-admin-setup                          # secrets only
#   DEPLOY_WORKER=1 make raffle-admin-setup          # also (re)deploy the orderbook worker
#   BINDING_KEY=<value> make raffle-admin-setup      # also set the console's ORDERBOOK_BINDING_KEY
#   ROTATE_TOKEN=1 make raffle-admin-setup           # replace an existing admin token
#
# What it does:
#   1. Orderbook worker (orderbook-1delta-rsk): if the RAFFLE_ADMIN_TOKEN secret is
#      missing, generate one, store it, and print it ONCE. Copy it into the password
#      manager. Cloudflare cannot show it again.
#   2. Console Pages project (raffle-admin-1delta): ORDERBOOK_BINDING_KEY, optional.
#      It must equal the worker's existing BINDING_KEY. That secret cannot be read
#      back, so pass the value in BINDING_KEY=…; without it this step is skipped.
#      The only effect of skipping: per-IP rate limits count the console, not you.
#   3. DEPLOY_WORKER=1: build the sdk and orderbook dists, then `wrangler deploy` the
#      worker. Only a deployed worker of this version has the /raffle routes.
#   4. Check through the live console: is the worker new enough, and does the token work?
#
# Needs `wrangler login` with access to the account. Never prints a secret it did
# not just create.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OB="$ROOT/packages/orderbook-worker"
ADMIN="$ROOT/packages/raffle-admin"
WRANGLER="$OB/node_modules/.bin/wrangler"
PROJECT="${PAGES_PROJECT:-raffle-admin-1delta}"
CONSOLE_URL="${CONSOLE_URL:-https://$PROJECT.pages.dev}"

log() { echo "[raffle-admin-setup] $*"; }
die() { echo "[raffle-admin-setup] FAIL: $*" >&2; exit 1; }

[ -x "$WRANGLER" ] || die "wrangler missing — run pnpm install"
command -v openssl >/dev/null || die "openssl not found"
command -v curl >/dev/null || die "curl not found"
export WRANGLER_SEND_METRICS=false
"$WRANGLER" whoami >/dev/null 2>&1 || die "not logged in — run: npx wrangler login"

# ── 3 first (if asked): a deploy before the secret is fine, and the check below needs it ──
if [ "${DEPLOY_WORKER:-0}" = "1" ]; then
  log "building the sdk + orderbook dists and deploying the orderbook worker"
  (cd "$ROOT/packages/sdk" && npx tsc -p tsconfig.json)
  (cd "$ROOT/packages/orderbook" && npx tsc -p tsconfig.json)
  (cd "$OB" && node scripts/bundle-check.mjs && "$WRANGLER" deploy) || die "worker deploy failed"
fi

# ── 1. the admin token on the worker ──
WORKER_SECRETS="$(cd "$OB" && "$WRANGLER" secret list 2>/dev/null || true)"
NEW_TOKEN=""
if grep -q '"RAFFLE_ADMIN_TOKEN"' <<<"$WORKER_SECRETS" && [ "${ROTATE_TOKEN:-0}" != "1" ]; then
  log "✓ worker secret RAFFLE_ADMIN_TOKEN already set (ROTATE_TOKEN=1 to replace it)"
else
  NEW_TOKEN="$(openssl rand -hex 32)"
  (cd "$OB" && printf '%s' "$NEW_TOKEN" | "$WRANGLER" secret put RAFFLE_ADMIN_TOKEN >/dev/null) || die "could not set RAFFLE_ADMIN_TOKEN"
  log "✓ worker secret RAFFLE_ADMIN_TOKEN set"
fi
grep -q '"BINDING_KEY"' <<<"$WORKER_SECRETS" || log "note: the worker has no BINDING_KEY secret, so the binding-key step is moot"

# ── 2. the binding key on the console's Pages project ──
PAGES_SECRETS="$(cd "$ADMIN" && "$WRANGLER" pages secret list --project-name "$PROJECT" 2>/dev/null || true)"
if grep -q "ORDERBOOK_BINDING_KEY" <<<"$PAGES_SECRETS"; then
  log "✓ Pages secret ORDERBOOK_BINDING_KEY already set on $PROJECT"
elif [ -n "${BINDING_KEY:-}" ]; then
  (cd "$ADMIN" && printf '%s' "$BINDING_KEY" | "$WRANGLER" pages secret put ORDERBOOK_BINDING_KEY --project-name "$PROJECT" >/dev/null) || die "could not set ORDERBOOK_BINDING_KEY"
  log "✓ Pages secret ORDERBOOK_BINDING_KEY set on $PROJECT (takes effect with the next console deploy)"
else
  log "– skipped ORDERBOOK_BINDING_KEY (optional; pass BINDING_KEY=<the worker's BINDING_KEY> to set it)"
fi

# ── 4. check through the live console ──
sleep 3 # a secret put deploys a new worker version; give it a moment
PUBLIC="$(curl -s --max-time 15 "$CONSOLE_URL/api/book/raffle" || true)"
case "$PUBLIC" in
  *'"live"'*) log "✓ the orderbook worker serves /raffle through $CONSOLE_URL" ;;
  *'"not found"'*) log "✗ the orderbook worker predates the raffle routes — rerun with DEPLOY_WORKER=1" ;;
  *) log "? $CONSOLE_URL/api/book/raffle answered: ${PUBLIC:0:160}" ;;
esac
if [ -n "$NEW_TOKEN" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "authorization: Bearer $NEW_TOKEN" "$CONSOLE_URL/api/book/raffle/admin/config" || true)"
  [ "$CODE" = "200" ] && log "✓ the new token opens the admin routes" || log "? admin check answered HTTP $CODE (404 = worker not yet redeployed)"
  echo
  echo "  RAFFLE_ADMIN_TOKEN (shown once — store it in the password manager now):"
  echo
  echo "    $NEW_TOKEN"
  echo
fi
