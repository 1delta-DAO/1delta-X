#!/usr/bin/env bash
# Startup smoke check of the three Rootstock beta Workers in the REAL runtime
# (workerd, through wrangler's local mode). Unit tests run the code in workerd too,
# but not the way a deployment STARTS it: workerd validates the main module's exports
# and the bindings at startup ("Incorrect type for map entry 'BOOK_MAX_BODY_BYTES'…")
# and refuses to serve anything when that fails — which the vitest pool never checks.
#
#   tools/workers-smoke.sh          (or: make workers-smoke)
#
# Starts, in parallel, each from its committed config:
#   • orderbook-worker  `wrangler dev --local`        → GET /health  must be 200 JSON
#   • filler-worker     `wrangler dev --local`        → GET /health  must be 200 JSON
#   • app (Pages)       `wrangler pages dev <dist>`   → GET / 200 with the CSP header,
#                                                       GET /api/book/fills 503 JSON
#                                                       (the worker ran: no binding set)
# and fails on any startup error in the logs. LOCAL ONLY: no secrets, no network
# calls of its own (the placeholder addresses keep both workers off the chain), never
# `wrangler deploy` / `login` / `secret`.
#
# The app dist: APP_DIST=<dir> if set; else packages/app/dist when its _worker.js is
# identical to public/_worker.js (a current `pnpm --filter @1delta-x/app build`); else
# a staged copy of public/ (where _worker.js lives) plus a stub index.html — the
# closest equivalent for the worker's startup, without a full Vite build.
#
# Knobs: SMOKE_PORT_BASE (default 18910: ports +1..+3, inspectors +101..+103),
# SMOKE_TIMEOUT_S (default 90), SKIP_BUILD=1 (do not rebuild the sdk / orderbook dists
# the workers bundle).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS="$ROOT/packages"
BASE="${SMOKE_PORT_BASE:-18910}"
TIMEOUT_S="${SMOKE_TIMEOUT_S:-90}"
OB_PORT=$((BASE + 1)) FW_PORT=$((BASE + 2)) APP_PORT=$((BASE + 3))
WRANGLER_OB="$PKGS/orderbook-worker/node_modules/.bin/wrangler"
WRANGLER_FW="$PKGS/filler-worker/node_modules/.bin/wrangler"

log() { echo "[workers-smoke] $*"; }
die() { echo "[workers-smoke] FAIL: $*" >&2; exit 1; }

[ -x "$WRANGLER_OB" ] && [ -x "$WRANGLER_FW" ] || die "wrangler missing — run pnpm install"
command -v curl >/dev/null || die "curl not found"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/workers-smoke.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -TERM -- "-$p" 2>/dev/null || true; done
  sleep 1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -KILL -- "-$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

for port in "$OB_PORT" "$FW_PORT" "$APP_PORT" $((BASE + 101)) $((BASE + 102)) $((BASE + 103)); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then die "port $port is in use (set SMOKE_PORT_BASE)"; fi
done

# The workers bundle the SDK's and the orderbook library's compiled dist/.
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "building the sdk and orderbook dists (SKIP_BUILD=1 to skip)"
  (cd "$PKGS/sdk" && npx tsc -p tsconfig.json) || die "sdk build"
  (cd "$PKGS/orderbook" && npx tsc -p tsconfig.json) || die "orderbook build"
fi

# ── the app dist ──
APP_DIR="${APP_DIST:-}"
if [ -z "$APP_DIR" ]; then
  if [ -f "$PKGS/app/dist/_worker.js" ] && cmp -s "$PKGS/app/dist/_worker.js" "$PKGS/app/public/_worker.js" && [ -f "$PKGS/app/dist/index.html" ]; then
    APP_DIR="$PKGS/app/dist"
    log "app: the built dist ($APP_DIR)"
  else
    APP_DIR="$TMP/app-dist"
    mkdir -p "$APP_DIR"
    cp -R "$PKGS/app/public/." "$APP_DIR/"
    printf '<!doctype html><html><head><meta charset="utf-8"><title>smoke</title></head><body>smoke</body></html>\n' >"$APP_DIR/index.html"
    log "app: staged public/ + a stub index.html (no current dist; APP_DIST=… to use one)"
  fi
fi
[ -f "$APP_DIR/_worker.js" ] || die "$APP_DIR has no _worker.js"

export WRANGLER_SEND_METRICS=false CI=1 NO_COLOR=1 FORCE_COLOR=0

start() { # name dir logfile cmd...
  local name=$1 dir=$2 logf=$3
  shift 3
  # `&` on the setsid'd command alone: $! is then the new session (process group)
  # leader, so `kill -- -$pid` takes wrangler AND its workerd children down.
  (cd "$dir" && {
    setsid "$@" </dev/null >"$logf" 2>&1 &
    echo $! >"$TMP/$name.pid"
  })
  PIDS+=("$(cat "$TMP/$name.pid")")
}

log "starting orderbook-worker :$OB_PORT, filler-worker :$FW_PORT, app (pages) :$APP_PORT"
start orderbook "$PKGS/orderbook-worker" "$TMP/orderbook.log" \
  "$WRANGLER_OB" dev --local --port "$OB_PORT" --inspector-port $((BASE + 101)) --persist-to "$TMP/state-ob" --show-interactive-dev-session=false
start filler "$PKGS/filler-worker" "$TMP/filler.log" \
  "$WRANGLER_FW" dev --local --port "$FW_PORT" --inspector-port $((BASE + 102)) --persist-to "$TMP/state-fw" --show-interactive-dev-session=false
start app "$PKGS/app" "$TMP/app.log" \
  "$WRANGLER_FW" pages dev "$APP_DIR" --port "$APP_PORT" --inspector-port $((BASE + 103)) --compatibility-date 2025-09-01 --persist-to "$TMP/state-app" --show-interactive-dev-session=false

# A startup (or build) error is fatal whatever /health says.
STARTUP_ERRORS='Incorrect type for map entry|failed to start|Uncaught|✘ \[ERROR\]|Build failed|Failed to build|Error: .*(main module|entrypoint)|No such module'
# wrangler colours its output even with NO_COLOR: match on the plain text.
plain() { sed -E 's/\x1b\[[0-9;]*m//g' "$1"; }

wait_ready() { # name logfile url
  local name=$1 logf=$2 url=$3 t=0
  while [ "$t" -lt "$TIMEOUT_S" ]; do
    if plain "$logf" | grep -Eq "$STARTUP_ERRORS"; then
      echo "──── $name log ────" >&2; plain "$logf" | tail -n 40 >&2
      die "$name: startup error: $(plain "$logf" | grep -Em1 "$STARTUP_ERRORS")"
    fi
    if grep -q "Ready on" "$logf" && curl -s -o /dev/null --max-time 5 "$url"; then return 0; fi
    sleep 1
    t=$((t + 1))
  done
  echo "──── $name log ────" >&2; plain "$logf" | tail -n 40 >&2
  die "$name: not ready within ${TIMEOUT_S}s"
}

check() { # name url expected-status body-regex [header-regex]
  local name=$1 url=$2 want=$3 re=$4 hre=${5:-}
  local body status headers
  body="$TMP/$name.body"
  headers="$TMP/$name.headers"
  status=$(curl -s -o "$body" -D "$headers" -w '%{http_code}' --max-time 10 "$url" || true)
  [ "$status" = "$want" ] || { cat "$body" >&2 || true; die "$name: GET $url → $status, want $want"; }
  grep -Eq "$re" "$body" || { cat "$body" >&2; die "$name: GET $url body does not match /$re/"; }
  if [ -n "$hre" ]; then grep -Eiq "$hre" "$headers" || { cat "$headers" >&2; die "$name: GET $url lacks header /$hre/"; }; fi
  log "✓ $name: GET ${url#http://127.0.0.1:} → $status"
}

wait_ready orderbook "$TMP/orderbook.log" "http://127.0.0.1:$OB_PORT/health"
wait_ready filler "$TMP/filler.log" "http://127.0.0.1:$FW_PORT/health"
wait_ready app "$TMP/app.log" "http://127.0.0.1:$APP_PORT/"

check orderbook "http://127.0.0.1:$OB_PORT/health" 200 '"chainId":30.*"logsUnsupported"'
check filler "http://127.0.0.1:$FW_PORT/health" 200 '"ok": ?(true|false)'
check app "http://127.0.0.1:$APP_PORT/" 200 '<html' "^content-security-policy: .*frame-ancestors 'none'"
check app-book "http://127.0.0.1:$APP_PORT/api/book/fills" 503 '"orderbook not configured"'

# Anything the runtime reported while serving those requests.
sleep 1
for n in orderbook filler app; do
  if plain "$TMP/$n.log" | grep -Eq "$STARTUP_ERRORS"; then
    plain "$TMP/$n.log" | tail -n 40 >&2
    die "$n: runtime error: $(plain "$TMP/$n.log" | grep -Em1 "$STARTUP_ERRORS")"
  fi
done
log "PASS: all three workers start and answer"
