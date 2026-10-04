#!/bin/bash
# Overnight driver for the Madeira two-variants build.
#
# Why this exists: the iteration loop is dispatch -> wait ~9 minutes ->
# read one log -> fix -> commit -> push -> dispatch again. That is far
# longer than a single turn, and the developer machine is a laptop that
# gets locked. This script does the waiting and the bookkeeping so the
# expensive wall-clock time is unattended; a human or agent only needs to
# look at the log afterwards.
#
# It does NOT try to fix anything. Reading a compile error and deciding
# what it means is the part that needs judgement, and a blind fixer would
# paper over real faults. What it does is: keep exactly one stage run in
# flight, wait for it, record its conclusion and its first error, and
# stop on success so the next stage can be attempted.
#
# Usage:
#   build/ci/overnight-loop.sh <stage> [max-iterations]
#
# Run it detached so it survives the shell that started it:
#   nohup bash build/ci/overnight-loop.sh wine-unix 6 > /tmp/madeira-loop.log 2>&1 &
#   disown
set -uo pipefail

STAGE="${1:?usage: overnight-loop.sh <stage> [max-iterations]}"
MAX="${2:-8}"
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOKEN_FILE="$HOME/.madeira-gh-token"
BRANCH="feature/two-variants-browser-and-linux"
REPO="sheltonsilas/Madeira"
LOG_DIR="$R/build/ci/overnight"
mkdir -p "$LOG_DIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

if [ ! -f "$TOKEN_FILE" ]; then
    log "FATAL: no token at $TOKEN_FILE"
    exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"
[ -n "$TOKEN" ] || { log "FATAL: empty token"; exit 1; }

# api <url> [extra curl args...]
#
# The URL goes FIRST so callers can append flags after it. It was read into a
# local and then dropped, so every call made with this helper invoked curl with
# no URL at all -- the driver dispatched a run and then went silent waiting for
# a lookup that had never happened.
api() {
    local url="$1"; shift
    curl -sL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$url" "$@"
}

dispatch() {
    local code
    # The network in this environment fails intermittently with getaddrinfo
    # errors, so a failed dispatch is retried rather than treated as fatal.
    for i in 1 2 3 4 5; do
        code=$(curl -sL -o /dev/null -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$REPO/actions/workflows/stage.yml/dispatches" \
            -d "{\"ref\":\"$BRANCH\",\"inputs\":{\"stage\":\"$STAGE\",\"runner\":\"macos-15\"}}")
        if [ "$code" = "204" ]; then log "dispatched (attempt $i)"; return 0; fi
        log "dispatch attempt $i -> $code"
        sleep 15
    done
    log "FATAL: could not dispatch after 5 attempts"
    return 1
}

wait_for_run() {   # wait_for_run <run_id> -> echoes conclusion
    local run="$1"
    while :; do
        local body status conclusion
        body=$(api "https://api.github.com/repos/$REPO/actions/runs/$run")
        status=$(printf '%s' "$body" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        conclusion=$(printf '%s' "$body" | python3 -c "import json,sys;print(json.load(sys.stdin).get('conclusion') or '')" 2>/dev/null || echo "")
        if [ "$status" = "completed" ]; then
            echo "$conclusion"
            return 0
        fi
        # 10 minutes is well past the stage's usual 9, and much longer than
        # the 180-minute workflow timeout, so a genuinely stuck run is
        # caught rather than polled forever.
        log "  run $run: $status, waiting"
        sleep 60
    done
}

for iter in $(seq 1 "$MAX"); do
    log "=== iteration $iter/$MAX: stage $STAGE ==="
    dispatch || exit 1
    sleep 40   # let the run register before looking it up

    run=""
    for i in 1 2 3 4 5 6; do
        run=$(api "https://api.github.com/repos/$REPO/actions/workflows/stage.yml/runs?branch=$BRANCH&per_page=1" \
              | python3 -c "
import json,sys
rs=json.load(sys.stdin).get('workflow_runs',[])
print(rs[0]['id'] if rs else '')
" 2>/dev/null || echo "")
        [ -n "$run" ] && break
        sleep 15
    done
    if [ -z "$run" ]; then log "FATAL: could not find the dispatched run"; exit 1; fi
    log "run $run"

    conclusion=$(wait_for_run "$run")
    log "run $run concluded: $conclusion"

    job=$(api "https://api.github.com/repos/$REPO/actions/runs/$run/jobs" \
          | python3 -c "
import json,sys
js=json.load(sys.stdin).get('jobs',[])
print(js[0]['id'] if js else '')
" 2>/dev/null || echo "")
    if [ -n "$job" ]; then
        api "https://api.github.com/repos/$REPO/actions/jobs/$job/logs" \
            -o "$LOG_DIR/$STAGE-$run.log"
        log "log saved: $LOG_DIR/$STAGE-$run.log"
        # Surface the first real compiler error inline: it is the only part
        # of a 3000-line log worth reading before deciding what to change.
        python3 - "$LOG_DIR/$STAGE-$run.log" <<'PY' 2>/dev/null || true
import re, sys
try:
    lines = open(sys.argv[1], errors="replace").read().splitlines()
except OSError:
    sys.exit(0)
strip = lambda s: re.sub(r'^\S+Z\s+', '', s)
pat = re.compile(r'(error:|::error|FAILED|Results: |Failed: |base objects|llvm-objcopy:)')
hits = [strip(l) for l in lines if pat.search(l)]
for h in hits[:25]:
    print("   ", h[:220])
PY
    fi

    if [ "$conclusion" = "success" ]; then
        log "SUCCESS: stage $STAGE is green. The next stage can be attempted."
        exit 0
    fi
    log "failure recorded; a fix is needed before the next iteration."
    # Do not burn the remaining budget re-running an unfixed stage.
    log "stopping so the failure can be read and fixed."
    exit 1
done

log "exhausted $MAX iterations"
exit 1
