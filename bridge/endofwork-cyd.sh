#!/usr/bin/env bash
# endofwork-cyd.sh — latch the END latch screen (WORK vs TASK).
#
# Usage: endofwork-cyd.sh [--bridge http://192.168.1.59:3847] [--running N] \
#          "Work title" ["Model name"]
#
# POSTs the ended-work event to the bridge. The bridge embeds it in
# GET /api/quota (and the USB-serial quota frames); the device latches
# END OF WORK (running=0, blinking) or END OF TASK (running>0, solid ice +
# "N agents still running") until dismiss (any tap / top key).
# Touch also POSTs /api/endofwork/dismiss to clear the bridge slot.
set -uo pipefail

BRIDGE="${CYD_BRIDGE_URL:-http://192.168.1.59:3847}"
RUNNING=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --bridge) BRIDGE="$2"; shift 2 ;;
    --running) RUNNING="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
done

TITLE="${1:?need a work title}"; shift || true
MODEL="${1:-}"
SESSION="${ENDWORK_SESSION:-}"

auth_args=()
if [[ -n "${CYD_TOKEN:-}" ]]; then auth_args=(-H "Authorization: Bearer $CYD_TOKEN"); fi

mkjson() {
  python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$1"
}
t_esc=$(mkjson "$TITLE") || exit 3
m_esc=$(mkjson "$MODEL") || exit 3
s_esc=$(mkjson "$SESSION") || exit 3

if ! resp=$(curl -s --max-time 10 -X POST "$BRIDGE/api/endofwork" \
  -H 'Content-Type: application/json' "${auth_args[@]}" \
  -d "{\"title\":$t_esc,\"model\":$m_esc,\"session\":$s_esc,\"running\":${RUNNING}}"); then
  echo "bridge POST failed: curl exit $?" >&2; exit 3
fi
echo "$resp"
