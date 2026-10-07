#!/usr/bin/env bash
# Local staging + load test of the two Rootstock beta Workers (orderbook-worker +
# filler-worker) against an anvil fork of Rootstock. LOCAL ONLY and NOT part of CI:
# it never runs `wrangler deploy`, `wrangler secret`, `wrangler login`, `--remote`
# or `--tunnel`, and touches no Cloudflare account. Keys: anvil's well-known dev
# keys (deployer #0, filler/operator #1) and keccak-derived test keys only.
#
#   packages/filler-worker/e2e/staging.sh all          # the whole campaign (both latency runs,
#                                                      #   restart test, soaks, report)
#   packages/filler-worker/e2e/staging.sh up [label]   # fork + deploy + proxy + wrangler dev
#   packages/filler-worker/e2e/staging.sh load|restart|soak|report|status
#   packages/filler-worker/e2e/staging.sh down
#   packages/filler-worker/e2e/staging.sh app-shape    # the app's market/limit/TWAP shapes vs the
#                                                      #   PRODUCTION gates (own stack, up → run → down)
#
# See the README section "Local staging + load test" for every knob. The run
# directory (configs, .dev.vars, DO state, logs, results) is e2e/.run/<label>/,
# gitignored; `staging.sh up` prints `export RUN_DIR=…` for the other subcommands.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
PACKAGES="$(cd "$PKG/.." && pwd)"
ROOT="$(cd "$PACKAGES/.." && pwd)"
TSX="$PKG/node_modules/.bin/tsx"
WRANGLER="$PKG/node_modules/.bin/wrangler"

FORK_URL="${FORK_URL:-https://public-node.rsk.co}"
BLOCK_TIME="${BLOCK_TIME:-2}"
ANVIL_PORT="${ANVIL_PORT:-18645}"
PROXY_PORT="${PROXY_PORT:-18646}"
WRANGLER_PORT="${WRANGLER_PORT:-18787}"
INSPECTOR_PORT="${INSPECTOR_PORT:-19329}"
CONFIRMATIONS="${CONFIRMATIONS:-1}"
# Filler knobs the throughput run lifts (production caps are reported, not exercised).
ROUTE_HOURLY_FILLS="${ROUTE_HOURLY_FILLS:-1000}"
HOURLY_USDT0="${HOURLY_USDT0:-100000}"
MAX_GAS_PRICE_GWEI="${MAX_GAS_PRICE_GWEI:-0.1}"
SUSHI_ENABLED="${SUSHI_ENABLED:-0}"
# `KEY = "value"` from a committed wrangler.toml (the production default).
toml_var() { sed -n "s/^$2 = \"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
# GATES=staging (default): expiry knobs scaled to the fork's 2 s blocks (production:
# 120 / 90 for ~30 s blocks — the same >= 4 blocks), so the short-expiry order kinds
# still exercise expiry races. GATES=production: the committed wrangler.toml values,
# read from the files (never hardcoded) — what `app-shape` runs. An explicit
# MIN_TTL_SECONDS / EXPIRY_MARGIN_SECONDS in the environment wins in either mode.
# `app-shape` always runs the production gates.
[ "${1:-}" = app-shape ] && GATES=production
GATES="${GATES:-staging}"
if [ "$GATES" = production ]; then
  MIN_TTL_SECONDS="${MIN_TTL_SECONDS:-$(toml_var "$PACKAGES/orderbook-worker/wrangler.toml" MIN_TTL_SECONDS)}"
  EXPIRY_MARGIN_SECONDS="${EXPIRY_MARGIN_SECONDS:-$(toml_var "$PKG/wrangler.toml" EXPIRY_MARGIN_SECONDS)}"
  [ -n "$MIN_TTL_SECONDS" ] && [ -n "$EXPIRY_MARGIN_SECONDS" ] || { echo "[staging] FAIL: could not read the production gates from the wrangler.toml files" >&2; exit 1; }
else
  MIN_TTL_SECONDS="${MIN_TTL_SECONDS:-15}"
  EXPIRY_MARGIN_SECONDS="${EXPIRY_MARGIN_SECONDS:-6}"
fi
LATENCY_MS="${LATENCY_MS:-0}"
JITTER_MS="${JITTER_MS:-0}"
RATE_LIMIT_RPS="${RATE_LIMIT_RPS:-}"
RUNS_DIR="${RUNS_DIR:-$HERE/.run}"

DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil dev key #0
OPERATOR_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d   # anvil dev key #1
WRBTC=0x542fDA317318eBF1d3DEAf76E0b632741A7e677d
USDT0=0x779Ded0c9e1022225f8E0630b35a9b54bE713736
WETH=0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590
USDRIF=0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37

log() { echo "[staging $(date +%H:%M:%S)] $*"; }
die() { echo "[staging] FAIL: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "$1 not found${2:+ — $2}"; }

current_run() {
  [ -n "${RUN_DIR:-}" ] && { echo "$RUN_DIR"; return; }
  [ -f "$RUNS_DIR/current" ] && { cat "$RUNS_DIR/current"; return; }
  die "no RUN_DIR (run 'staging.sh up' first)"
}

# The ports / block time a run was started with (so later subcommands match it).
load_stack_env() { [ -f "$1/stack.env" ] && . "$1/stack.env"; return 0; }

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

wait_http() { # url seconds
  for _ in $(seq 1 "$2"); do curl -sf -o /dev/null "$1" && return 0; sleep 1; done
  return 1
}

# ──────────────────── processes ────────────────────

start_anvil() {
  local run=$1
  log "anvil fork of $FORK_URL @ block $FORK_BLOCK on :$ANVIL_PORT (block time ${BLOCK_TIME}s)"
  # --gas-price/--block-base-fee-per-gas 0: anvil mines Rootstock-priced legacy txs.
  # (eth_gasPrice still answers 1 gwei; the proxy answers Rootstock's price instead.)
  setsid anvil --fork-url "$FORK_URL" --fork-block-number "$FORK_BLOCK" --port "$ANVIL_PORT" \
    --block-time "$BLOCK_TIME" --gas-price "$GAS_PRICE_WEI" --block-base-fee-per-gas 0 --silent \
    </dev/null >"$run/anvil.log" 2>&1 &
  echo $! >"$run/pids/anvil"
  for _ in $(seq 1 90); do cast chain-id --rpc-url "http://127.0.0.1:$ANVIL_PORT" >/dev/null 2>&1 && break; sleep 1; done
  [ "$(cast chain-id --rpc-url "http://127.0.0.1:$ANVIL_PORT")" = 30 ] || die "anvil fork is not chain 30"
  # anvil keeps the fork block's time base (minutes behind the host); sync the chain
  # clock to the host so order expiries mean the same to the book and to Settlement.
  cast rpc evm_setNextBlockTimestamp "$(( $(date +%s) + BLOCK_TIME ))" --rpc-url "http://127.0.0.1:$ANVIL_PORT" >/dev/null
}

start_proxy() {
  local run=$1
  log "rpc proxy :$PROXY_PORT → anvil (latency ${LATENCY_MS}±${JITTER_MS} ms${RATE_LIMIT_RPS:+, rate limit $RATE_LIMIT_RPS rps})"
  # `{ cmd & echo $!; }` after the cd: $! must be the setsid'd process itself (a new
  # process group we can kill), not a forked subshell holding our stdout open.
  (cd "$PKG" && {
    PROXY_PORT=$PROXY_PORT UPSTREAM="http://127.0.0.1:$ANVIL_PORT" RUN_DIR="$run" LATENCY_MS=$LATENCY_MS JITTER_MS=$JITTER_MS \
      RATE_LIMIT_RPS=$RATE_LIMIT_RPS GAS_PRICE_WEI=$GAS_PRICE_WEI DENY_METHODS="${DENY_METHODS:-}" setsid "$TSX" e2e/rpc-proxy.ts </dev/null >"$run/proxy.log" 2>&1 &
    echo $! >"$run/pids/proxy"
  })
  wait_http "http://127.0.0.1:$PROXY_PORT/__stats" 30 || die "proxy did not start (see $run/proxy.log)"
}

wrangler_start() {
  local run=$1
  echo "==== wrangler dev start $(date -Is)" >>"$run/wrangler.log"
  local mark; mark=$(wc -l <"$run/wrangler.log")
  log "wrangler dev (gateway + orderbook + filler in ONE session) on :$WRANGLER_PORT, state in $run/state"
  (cd "$PKG" && {
    WRANGLER_SEND_METRICS=false CI=1 setsid "$WRANGLER" dev --local \
      -c "$run/gateway/wrangler.toml" -c "$run/orderbook/wrangler.toml" -c "$run/filler/wrangler.toml" \
      --persist-to "$run/state" --port "$WRANGLER_PORT" --inspector-port "$INSPECTOR_PORT" \
      --show-interactive-dev-session=false </dev/null >>"$run/wrangler.log" 2>&1 &
    echo $! >"$run/pids/wrangler"
  })
  for _ in $(seq 1 120); do
    tail -n +"$mark" "$run/wrangler.log" | grep -q "Ready on" && break
    tail -n +"$mark" "$run/wrangler.log" | grep -q "failed to start" && die "wrangler dev failed (see $run/wrangler.log)"
    sleep 1
  done
  wait_http "http://127.0.0.1:$WRANGLER_PORT/ob/health" 60 || die "orderbook not reachable (see $run/wrangler.log)"
  # Warm the app's /api/book path too (Pages worker → ORDERBOOK binding): /ob/health
  # bypasses it, and the first request down it under wrangler dev could drop with
  # "Network connection lost" — which a run then blamed on its first ticket.
  wait_http "http://127.0.0.1:$WRANGLER_PORT/api/book/orders" 30 || die "app book proxy not reachable (see $run/wrangler.log)"
}

# SIGKILL the whole wrangler process group (wrangler + workerd): a crash, not a shutdown.
wrangler_kill() {
  local run=$1 sig=${2:-KILL}
  if alive "$run/pids/wrangler"; then
    kill -"$sig" -- -"$(cat "$run/pids/wrangler")" 2>/dev/null || kill -"$sig" "$(cat "$run/pids/wrangler")" 2>/dev/null || true
  fi
  for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:$WRANGLER_PORT/ob/health" || break; sleep 1; done
  rm -f "$run/pids/wrangler"
}

stop_pid() { # pidfile
  if alive "$1"; then kill -TERM -- -"$(cat "$1")" 2>/dev/null || kill -TERM "$(cat "$1")" 2>/dev/null || true; fi
  rm -f "$1"
}

# ──────────────────── configs ────────────────────

gen_configs() {
  local run=$1
  mkdir -p "$run/gateway" "$run/orderbook" "$run/filler" "$run/state"
  # The committed configs verbatim (every production default kept), only `main`
  # pointed back at the package; overrides + secrets go in a .dev.vars next to each.
  sed -e "s#^main = \"src/index.ts\"#main = \"$PACKAGES/orderbook-worker/src/index.ts\"#" "$PACKAGES/orderbook-worker/wrangler.toml" >"$run/orderbook/wrangler.toml"
  sed -e "s#^main = \"src/index.ts\"#main = \"$PACKAGES/filler-worker/src/index.ts\"#" "$PACKAGES/filler-worker/wrangler.toml" >"$run/filler/wrangler.toml"
  grep -q "^main = \"$PACKAGES" "$run/orderbook/wrangler.toml" && grep -q "^main = \"$PACKAGES" "$run/filler/wrangler.toml" || die "could not rewrite main in the committed wrangler.toml files"
  cat >"$run/gateway/wrangler.toml" <<EOF
# Staging-harness edge (generated, local only): see e2e/gateway/index.ts.
name = "staging-gateway"
main = "$HERE/gateway/index.ts"
compatibility_date = "2025-09-01"

[[services]]
binding = "ORDERBOOK"
service = "orderbook-1delta-rsk"

[[services]]
binding = "FILLER"
service = "filler-1delta-rsk"
EOF
  local proxy="http://127.0.0.1:$PROXY_PORT"
  umask 077
  cat >"$run/gateway/.dev.vars" <<EOF
ORDERBOOK_BINDING_KEY=$BINDING_KEY
EOF
  # The RPC goes in RPC_URL_SECRET, as in production; the RPC_URL var points at a
  # proxy tag nothing may ever call (`ob-var` / `filler-var` in the proxy's stats
  # would prove the secret did NOT win). ALLOWED_TOKENS: the committed default.
  cat >"$run/orderbook/.dev.vars" <<EOF
RPC_URL_SECRET=$proxy/ob
RPC_URL=$proxy/ob-var
CHAIN_ID=30
SETTLEMENT=$SETTLEMENT
PERMIT3=$PERMIT3
LENS=$LENS
START_BLOCK=$START_BLOCK
CONFIRMATIONS=$CONFIRMATIONS
MIN_TTL_SECONDS=$MIN_TTL_SECONDS
BINDING_KEY=$BINDING_KEY
${EXTRA_ORDERBOOK_VARS:-}
EOF
  cat >"$run/filler/.dev.vars" <<EOF
RPC_URL_SECRET=$proxy/filler
RPC_URL=$proxy/filler-var
EXPIRY_MARGIN_SECONDS=$EXPIRY_MARGIN_SECONDS
CHAIN_ID=30
SETTLEMENT=$SETTLEMENT
PERMIT3=$PERMIT3
LENS=$LENS
AGGREGATOR_SOLVER=$SOLVER
PRIVATE_KEY=$OPERATOR_KEY
ADMIN_TOKEN=$ADMIN_TOKEN
ORDERBOOK_BINDING_KEY=$BINDING_KEY
ALERT_WEBHOOK_URL=$proxy/__webhook
DRY_RUN=0
MAX_GAS_PRICE_GWEI=$MAX_GAS_PRICE_GWEI
SUSHI_ENABLED=$SUSHI_ENABLED
RBTC_PRICE_USD=$RBTC_USD
ROUTE_PROFIT_RECIPIENT=$TREASURY
ROUTE_HOURLY_FILLS=$ROUTE_HOURLY_FILLS
HOURLY_USDT0=$HOURLY_USDT0
${EXTRA_FILLER_VARS:-}
EOF
  umask 022
}

# ──────────────────── subcommands ────────────────────

cmd_up() {
  local label=${1:-${LABEL:-run-$(date +%Y%m%d-%H%M%S)}}
  need anvil "install foundry"; need cast; need forge; need curl; need python3
  [ -x "$TSX" ] || die "tsx missing — pnpm install"
  [ -x "$WRANGLER" ] || die "wrangler missing — pnpm install"
  local run="$RUNS_DIR/$label"
  [ -e "$run" ] && die "$run exists — pick another label or remove it"
  mkdir -p "$run/pids" "$run/results"
  echo "$run" >"$RUNS_DIR/current.tmp" && mv "$RUNS_DIR/current.tmp" "$RUNS_DIR/current"
  cat >"$run/stack.env" <<EOF
ANVIL_PORT=$ANVIL_PORT
PROXY_PORT=$PROXY_PORT
WRANGLER_PORT=$WRANGLER_PORT
INSPECTOR_PORT=$INSPECTOR_PORT
BLOCK_TIME=$BLOCK_TIME
EOF
  export RUN_DIR=$run LABEL=$label

  # Workers bundle the SDK's / orderbook library's dist/: build if missing.
  [ -f "$PACKAGES/sdk/dist/index.js" ] || (cd "$ROOT" && pnpm --filter @1delta-x/sdk build >/dev/null)
  [ -f "$PACKAGES/orderbook/dist/pure.js" ] || (cd "$ROOT" && pnpm --filter @1delta-x/orderbook build >/dev/null)

  GAS_PRICE_WEI=${GAS_PRICE_WEI:-$(cast gas-price --rpc-url "$FORK_URL" 2>/dev/null || echo 26065600)}
  FORK_BLOCK=${FORK_BLOCK:-$(( $(cast block-number --rpc-url "$FORK_URL") - 2 ))}
  export GAS_PRICE_WEI FORK_BLOCK
  echo "$FORK_BLOCK" >"$run/fork-block"
  start_anvil "$run"
  local rpc="http://127.0.0.1:$ANVIL_PORT"

  log "setup: deployer floor tokens"
  (cd "$PKG" && ANVIL_URL=$rpc DEPLOYER_KEY=$DEPLOYER_KEY "$TSX" e2e/setup.ts pre-deploy) | tee -a "$run/setup.log"
  START_BLOCK=$(cast block-number --rpc-url "$rpc")
  local deploy_args="--private-key $DEPLOYER_KEY --gas-estimate-multiplier 110 --legacy --slow"
  log "deploy: Permit3 + Settlement + SettlementLens (make deploy-core)"
  make -s -C "$ROOT" deploy-core RPC="$rpc" DEPLOY_ARGS="$deploy_args" >"$run/deploy-core.log" 2>&1 || { tail -30 "$run/deploy-core.log"; die "deploy-core"; }
  grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" "$run/deploy-core.log" || die "deploy-core did not complete"
  addr_of() { awk -v n="$1" '$1==n {getline; print $2; exit}' "$run/deploy-core.log"; }
  PERMIT3=$(addr_of Permit3); SETTLEMENT=$(addr_of Settlement); LENS=$(addr_of SettlementLens)
  OPERATOR=$(cast wallet address "$OPERATOR_KEY")
  log "deploy: AggregatorFillSolver gated to $OPERATOR (make deploy-aggregator-fill)"
  SETTLEMENT=$SETTLEMENT OPERATORS=$OPERATOR FLOOR_TOKENS="$WRBTC,$USDT0,$WETH,$USDRIF" \
    make -s -C "$ROOT" deploy-aggregator-fill RPC="$rpc" DEPLOY_ARGS="$deploy_args" >"$run/deploy-agg.log" 2>&1 || { tail -30 "$run/deploy-agg.log"; die "deploy-aggregator-fill"; }
  grep -q "immutables verified" "$run/deploy-agg.log" || die "solver deploy did not verify"
  SOLVER=$(awk '$1=="AggregatorFillSolver" && $2 ~ /^0x/ {print $2; exit}' "$run/deploy-agg.log")
  SANDBOX=$(awk '$1=="RouteSandbox" && $2 ~ /^0x/ {print $2; exit}' "$run/deploy-agg.log")
  log "   Permit3 $PERMIT3  Settlement $SETTLEMENT  Lens $LENS  Solver $SOLVER  Sandbox $SANDBOX"

  TREASURY=$(cast wallet address "$(cast keccak "1delta-staging:treasury")")
  ADMIN_TOKEN=$(openssl rand -hex 32)
  BINDING_KEY=$(openssl rand -hex 32)
  log "setup: MoC oracle keep-alive, operator funding, RBTC price"
  local out
  out=$(cd "$PKG" && ANVIL_URL=$rpc RUN_DIR=$run LABEL=$label FORK_URL=$FORK_URL FORK_BLOCK=$FORK_BLOCK START_BLOCK=$START_BLOCK \
    BLOCK_TIME=$BLOCK_TIME PERMIT3=$PERMIT3 SETTLEMENT=$SETTLEMENT LENS=$LENS SOLVER=$SOLVER SANDBOX=$SANDBOX \
    OPERATOR_KEY=$OPERATOR_KEY DEPLOYER_KEY=$DEPLOYER_KEY TREASURY=$TREASURY ADMIN_TOKEN=$ADMIN_TOKEN BINDING_KEY=$BINDING_KEY \
    PROXY_URL="http://127.0.0.1:$PROXY_PORT" GATEWAY_URL="http://127.0.0.1:$WRANGLER_PORT" GAS_PRICE_WEI=$GAS_PRICE_WEI \
    LATENCY_MS=$LATENCY_MS JITTER_MS=$JITTER_MS "$TSX" e2e/setup.ts post-deploy)
  echo "$out" | tee -a "$run/setup.log"
  RBTC_USD=$(echo "$out" | sed -n 's/^RBTC_USD=//p')

  start_proxy "$run"
  gen_configs "$run"
  # Record the (non-secret) worker overrides in env.json for the report.
  python3 - "$run" <<'PYEOF'
import json, sys
run = sys.argv[1]
env = json.load(open(f"{run}/env.json"))
secret = {"PRIVATE_KEY", "ADMIN_TOKEN", "BINDING_KEY", "ORDERBOOK_BINDING_KEY"}
for w in ("orderbook", "filler"):
    vs = {}
    for line in open(f"{run}/{w}/.dev.vars"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            vs[k] = "(secret)" if k in secret else v
    env["workerVars"][w] = vs
json.dump(env, open(f"{run}/env.json", "w"), indent=1)
PYEOF
  wrangler_start "$run"
  # Arm both Durable Objects' alarm loops (first request) and fire each cron once.
  curl -sf -o /dev/null "http://127.0.0.1:$WRANGLER_PORT/filler/health" || true
  local ex="http://127.0.0.1:$WRANGLER_PORT/cdn-cgi/explorer/api/local/scheduled"
  for w in orderbook-1delta-rsk filler-1delta-rsk; do
    echo "cron $w: $(curl -s -X POST "$ex?worker=$w" -H 'content-type: application/json' -d '{"cron":"* * * * *"}')" | tee -a "$run/setup.log"
  done
  log "up: $run"
  echo "export RUN_DIR=$run"
}

cmd_down() {
  local run; run=$(current_run); load_stack_env "$run"
  log "down: $run"
  wrangler_kill "$run" TERM
  stop_pid "$run/pids/proxy"
  stop_pid "$run/pids/anvil"
}

# Process control the TypeScript drivers call back into (restart test).
cmd_wrangler() { # stop|kill|start
  local run; run=$(current_run); load_stack_env "$run"
  # gen_configs is not re-run: the generated configs and .dev.vars persist in $run.
  case "${1:-}" in
    kill) wrangler_kill "$run" KILL ;;
    stop) wrangler_kill "$run" TERM ;;
    start) wrangler_start "$run" ;;
    *) die "wrangler kill|stop|start" ;;
  esac
}

run_ts() { local run; run=$(current_run); load_stack_env "$run"; (cd "$PKG" && RUN_DIR=$run BLOCK_TIME=$BLOCK_TIME "$TSX" "e2e/$1" "${@:2}"); }

cmd_all() {
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  # Pin ONE fork block for every run so both latency runs start from the same chain state.
  export FORK_BLOCK=${FORK_BLOCK:-$(( $(cast block-number --rpc-url "$FORK_URL") - 2 ))}
  local lat0="$stamp-lat0" lat150="$stamp-lat150"
  LATENCY_MS=0 JITTER_MS=0 cmd_up "$lat0"
  RUN_DIR="$RUNS_DIR/$lat0" run_ts load.ts || log "load (0 ms) reported failures"
  RUN_DIR="$RUNS_DIR/$lat0" cmd_down
  LATENCY_MS=150 JITTER_MS=50 cmd_up "$lat150"
  RUN_DIR="$RUNS_DIR/$lat150" run_ts load.ts || log "load (150 ms) reported failures"
  RUN_DIR="$RUNS_DIR/$lat150" run_ts restart.ts || log "restart test reported failures"
  RUN_DIR="$RUNS_DIR/$lat150" run_ts soak.ts || log "soak reported failures"
  RUN_DIR="$RUNS_DIR/$lat150" cmd_down
  (cd "$PKG" && "$TSX" e2e/report.ts "$RUNS_DIR/$lat0" "$RUNS_DIR/$lat150")
}

# The app's real market / limit / TWAP shapes against the PRODUCTION gates (tasks/03):
# its own stack (fork + deploy + workers with GATES=production), e2e/app-shape.ts, down.
# Exit status = the run's. Perturb one constant to see it fail, e.g.
#   APP_MARKET_TTL_SECONDS=60 | MIN_TTL_SECONDS=400 | EXPIRY_MARGIN_SECONDS=250 staging.sh app-shape
cmd_app_shape() {
  local label="${LABEL:-app-shape-$(date +%Y%m%d-%H%M%S)}"
  local run="$RUNS_DIR/$label"
  # Always tear the stack down (also when `up` dies half-way).
  trap "RUN_DIR='$run' cmd_down >/dev/null 2>&1 || true" EXIT
  cmd_up "$label"
  local rc=0
  RUN_DIR="$run" run_ts app-shape.ts || rc=$?
  RUN_DIR="$run" cmd_down
  trap - EXIT
  [ "$rc" = 0 ] && log "app-shape PASSED ($run/results/app-shape.json)" || log "app-shape FAILED (exit $rc; $run/results/app-shape.json)"
  return "$rc"
}

case "${1:-all}" in
  up) shift; cmd_up "$@" ;;
  down) cmd_down ;;
  load) shift; run_ts load.ts "$@" ;;
  restart) shift; run_ts restart.ts "$@" ;;
  soak) shift; run_ts soak.ts "$@" ;;
  report) shift; (cd "$PKG" && "$TSX" e2e/report.ts "${@:-$(current_run)}") ;;
  wrangler) shift; cmd_wrangler "$@" ;;
  status) run=$(current_run); load_stack_env "$run"; echo "$run"; for p in anvil proxy wrangler; do alive "$run/pids/$p" && echo "$p up" || echo "$p down"; done ;;
  all) cmd_all ;;
  app-shape) cmd_app_shape ;;
  *) die "usage: staging.sh all|app-shape|up [label]|load|restart|soak|report [runs…]|wrangler kill|stop|start|status|down" ;;
esac
