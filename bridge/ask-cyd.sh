#!/usr/bin/env bash
# ask-cyd.sh — ask via CYD hardware buttons, fall back to the app on timeout.
#
# Usage: ask-cyd.sh [--timeout 30] [--bridge http://192.168.1.59:3847] \
#          "Question?" "Option 1" "Option 2" ["Option 3" ...]
#
# Posts the question to the bridge (CYD pops 05 · ASK), polls for the
# hardware answer until the timeout, prints the chosen label and exits 0.
# If the CYD does not answer in time, prints TIMEOUT to stderr and exits 2
# so the caller asks back in the app (native question picker).
#
# Example agent flow:
#   if ans=$(ask-cyd.sh "Which model?" "Quick" "Full" "Skip"); then
#     echo "hardware answered: $ans"
#   else
#     echo "no hardware answer — ask in app"
#   fi
set -euo pipefail

TIMEOUT=30
BRIDGE="${CYD_BRIDGE_URL:-http://192.168.1.59:3847}"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 3 ;;
  esac
done

QUESTION="${1:?need a question}"; shift
if [[ $# -lt 1 ]]; then echo "need at least 1 option" >&2; exit 3; fi

opts_json=""
for o in "$@"; do
  o_esc=$(printf '%s' "$o" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
  if [[ -n "$opts_json" ]]; then opts_json="$opts_json, "; fi
  opts_json="$opts_json$o_esc"
done
q_esc=$(printf '%s' "$QUESTION" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")

resp=$(curl -s --max-time 10 -X POST "$BRIDGE/api/ask" \
  -H 'Content-Type: application/json' \
  -d "{\"question\":$q_esc,\"options\":[$opts_json],\"timeout_sec\":$TIMEOUT}")
qid=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")
if [[ -z "$qid" ]]; then echo "bridge POST failed: $resp" >&2; exit 3; fi

deadline=$(( $(date +%s) + TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
  sleep 2
  st=$(curl -s --max-time 10 "$BRIDGE/api/ask?id=$qid" || true)
  answered=$(printf '%s' "$st" | python3 -c "import json,sys
try: d=json.load(sys.stdin); print(d.get('answer','') if d.get('answered') else '')
except Exception: print('')" 2>/dev/null || true)
  if [[ -n "$answered" ]]; then
    label=$(printf '%s' "$st" | python3 -c "import json,sys
d=json.load(sys.stdin); a=d.get('answer','')
print(next((o.get('label',a) for o in d.get('options',[]) if o.get('id')==a), a))")
    printf '%s\n' "$label"
    exit 0
  fi
done

echo "TIMEOUT: no hardware answer in ${TIMEOUT}s" >&2
exit 2
