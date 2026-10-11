#!/usr/bin/env bash
# Filler admin shortcuts. Reads FILLER_ADMIN_URL + ADMIN_TOKEN from ../.admin.env
# (gitignored) or the environment.
#   scripts/admin.sh pause | resume | status | fills | tick | dry-run on|off
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$here/.admin.env" ] && set -a && . "$here/.admin.env" && set +a
: "${FILLER_ADMIN_URL:?set FILLER_ADMIN_URL (in .admin.env)}"
: "${ADMIN_TOKEN:?set ADMIN_TOKEN (in .admin.env)}"
call() { curl -sS -m 20 -X "$1" -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' ${3:+-d "$3"} "$FILLER_ADMIN_URL$2"; echo; }
case "${1:-}" in
  pause)   call POST /pause ;;
  resume)  call POST /resume ;;
  status)  call GET /status ;;
  fills)   call GET /fills ;;
  tick)    call POST /tick ;;
  dry-run) case "${2:-}" in on) call POST /dry-run '{"on":true}' ;; off) call POST /dry-run '{"on":false}' ;; *) echo "dry-run on|off" >&2; exit 2 ;; esac ;;
  *) echo "usage: $0 pause|resume|status|fills|tick|dry-run on|off" >&2; exit 2 ;;
esac
