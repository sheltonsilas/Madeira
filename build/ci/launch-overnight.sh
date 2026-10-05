#!/bin/bash
# Start the overnight driver so it survives this shell, this agent and the
# laptop being locked, and hold the machine awake for as long as it runs.
#
# Usage:
#   bash build/ci/launch-overnight.sh <target> [<target> ...]
#   bash build/ci/launch-overnight.sh status
#   bash build/ci/launch-overnight.sh stop
#
# A target is a stage.yml stage name, or `build` for the full run that packages
# the IPAs and publishes the release. See build/ci/overnight-loop.sh.
#
# Everything the driver says lands in build/ci/overnight/: driver-<time>.log,
# driver-<time>.err, heartbeat, and on failure NEEDS_FIX.md with the run URL and
# where the log is. IPA-READY.md appears when the release exists.
#
# Why PowerShell's Start-Process rather than `nohup ... &`: a detached bash child
# still belongs to the console Windows created for the tool call, and when that
# console goes away the child does too. Start-Process makes a process with no
# console at all, which is what survives the laptop being locked and the agent
# session ending.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$R/build/ci/overnight"
mkdir -p "$DIR"

PS=""
for c in powershell.exe /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    if command -v "$c" >/dev/null 2>&1; then PS="$c"; break; fi
done
[ -n "$PS" ] || { echo "no powershell.exe found; this launcher is Windows-only" >&2; exit 1; }

# Git Bash's own bash.exe, so the driver runs in the same environment as here.
BASH_EXE="$(cd / && command -v bash)"
[ -n "$BASH_EXE" ] || { echo "no bash found" >&2; exit 1; }
WIN_BASH="$(cygpath -w "$BASH_EXE" 2>/dev/null || echo "$BASH_EXE")"
WIN_SH="$(cygpath -w "$R/build/ci/overnight-loop.sh" 2>/dev/null || echo "$R/build/ci/overnight-loop.sh")"
WIN_KA="$(cygpath -w "$R/build/ci/keep-awake.ps1" 2>/dev/null || echo "$R/build/ci/keep-awake.ps1")"
WIN_KALOG="$(cygpath -w "$DIR/keep-awake.log" 2>/dev/null || echo "$DIR/keep-awake.log")"

case "${1:-}" in
    status)
        echo "=== driver ==="
        if [ -f "$DIR/driver.pid" ] && kill -0 "$(cat "$DIR/driver.pid")" 2>/dev/null; then
            echo "running (pid $(cat "$DIR/driver.pid"))"
        else
            echo "not running"
        fi
        echo "=== heartbeat (last poll, UTC) ==="
        cat "$DIR/heartbeat" 2>/dev/null || echo "(none yet)"
        echo "=== in flight ==="
        cat "$DIR/inflight" 2>/dev/null || echo "(nothing)"
        echo "=== green targets at this commit ==="
        cat "$DIR/state" 2>/dev/null || echo "(none)"
        echo "=== latest output ==="
        # The driver writes its progress to stderr on purpose (see the comment
        # on log() in overnight-loop.sh: stdout is captured by wait_for_run), so
        # the newest .err is usually the interesting file, not the newest .log.
        ls -t "$DIR"/driver-*.log "$DIR"/driver-*.err 2>/dev/null | head -1 | while read -r f; do
            echo "$f"
            tail -15 "$f"
        done
        echo "=== keep-awake ==="
        tail -3 "$DIR/keep-awake.log" 2>/dev/null || echo "(none)"
        exit 0
        ;;
    stop)
        if [ -f "$DIR/driver.pid" ]; then
            pid="$(cat "$DIR/driver.pid")"
            echo "stopping driver pid $pid"
            kill "$pid" 2>/dev/null || true
            rm -f "$DIR/driver.pid"
        fi
        # The keep-awake holder is a powershell.exe with our script on its
        # command line; the driver's own exit is not enough to end it.
        "$PS" -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -like '*keep-awake.ps1*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" 2>/dev/null || true
        echo "stopped"
        exit 0
        ;;
esac

[ "${#@}" -gt 0 ] || { echo "usage: launch-overnight.sh <target> [<target> ...] | status | stop" >&2; exit 2; }

TS="$(date -u +%Y%m%d-%H%M%S)"
LOG="$DIR/driver-$TS.log"
ERR="$DIR/driver-$TS.err"

# 1. Keep the machine awake. Without this a locked laptop may suspend and the
#    loop stops noticing its runs until someone opens it again.
"$PS" -NoProfile -ExecutionPolicy Bypass -Command \
    "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$WIN_KA','-LogFile','$WIN_KALOG' -WindowStyle Hidden" \
    >/dev/null 2>&1 || true

# 2. The driver itself, with no console of its own.
args=()
for t in "$@"; do args+=("'$t'"); done
"$PS" -NoProfile -ExecutionPolicy Bypass -Command \
    "Start-Process -FilePath '$WIN_BASH' -ArgumentList '$WIN_SH',$(IFS=,; echo "${args[*]}") -RedirectStandardOutput '$(cygpath -w "$LOG" 2>/dev/null || echo "$LOG")' -RedirectStandardError '$(cygpath -w "$ERR" 2>/dev/null || echo "$ERR")' -WindowStyle Hidden" \
    >/dev/null 2>&1 || true

sleep 3
echo "launched: bash overnight-loop.sh $*"
echo "  log:   $LOG"
echo "  err:   $ERR"
echo "  check: bash build/ci/launch-overnight.sh status"
[ -f "$LOG" ] && { echo "--- first lines ---"; sed -n '1,10p' "$LOG"; }
