#!/bin/bash
# Overnight driver for the Madeira two-variants build -- a chain, not one stage.
#
# Why this exists: the iteration loop is dispatch -> wait ~10 minutes -> read one
# log -> fix -> commit -> push -> dispatch again. That is far longer than a single
# turn, and the machine that dispatches is a laptop that gets locked and whose
# display turns off. This script does the waiting and the bookkeeping, so the
# expensive wall-clock time is unattended.
#
# It does NOT try to fix anything. Reading a compile error and deciding what it
# means is the part that needs judgement, and a blind fixer would paper over real
# faults. What it does is: keep exactly one run in flight, wait for it, record its
# conclusion and its first error, and move to the next target only when the
# current one is green.
#
# Usage:
#   build/ci/overnight-loop.sh <target> [<target> ...]
#
# A target is either a stage name accepted by .github/workflows/stage.yml, or the
# word `build`, which dispatches the full build.yml run -- both variants, the IPAs
# and the published release -- and then reports where they are.
#
# Run it detached; build/ci/launch-overnight.sh does that and also stops the
# machine from sleeping:
#   bash build/ci/launch-overnight.sh rppairing-ios xcodebuild build
#
# State lives in build/ci/overnight/ (gitignored):
#   state       "<target> <sha>" per green target, so a restart does not redo work
#   inflight    "<target> <run_id> <sha>" while a run is being waited on
#   heartbeat   rewritten every poll, so a watcher can see it is alive
#   <target>-<run>.log, NEEDS_FIX.md, IPA-READY.md, ipas/
set -uo pipefail

if [ "${#@}" -eq 0 ]; then
    echo "usage: overnight-loop.sh <target> [<target> ...]  (a stage name, or 'build')" >&2
    exit 2
fi
TARGETS=("$@")

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$R/build/ci/overnight"
STATE="$DIR/state"
INFLIGHT="$DIR/inflight"
HEARTBEAT="$DIR/heartbeat"
LOCK="$DIR/driver.pid"
TOKEN_FILE="$HOME/.madeira-gh-token"
BRANCH="feature/two-variants-browser-and-linux"
REPO="sheltonsilas/Madeira"
API="https://api.github.com/repos/$REPO"
mkdir -p "$DIR"

# Progress lines go to stderr: wait_for_run is called inside $(...) and command
# substitution captures stdout only. When these went to stdout they were swallowed
# into the returned conclusion and a live run looked exactly like a hung one.
log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- one driver at a time -----------------------------------------------------
if [ -f "$LOCK" ]; then
    other=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        die "another driver is running (pid $other). Stop it first, or delete $LOCK if it is a leftover."
    fi
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

[ -f "$TOKEN_FILE" ] || die "no token at $TOKEN_FILE"
TOKEN="$(cat "$TOKEN_FILE")"
[ -n "$TOKEN" ] || die "empty token in $TOKEN_FILE"

api() {   # api <url> [extra curl args...]
    local url="$1"; shift
    curl -sL --retry 3 --retry-connrefused \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
        "$url" "$@"
}

jget() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo ""; }

# --- the commit has to be on the branch the workflows check out --------------
SHA="$(git -C "$R" rev-parse HEAD)"
REMOTE_SHA="$(api "$API/branches/$BRANCH" | jget "d['commit']['sha']")"
[ -n "$REMOTE_SHA" ] || die "could not read the branch head (network?)"
if [ "$SHA" != "$REMOTE_SHA" ]; then
    die "HEAD ($SHA) is not the tip of $BRANCH ($REMOTE_SHA); push first, the workflows build the branch"
fi
log "driving ${TARGETS[*]} at ${SHA:0:7}"

# --- dispatch -----------------------------------------------------------------
dispatch() {   # dispatch <workflow file> [json input object]
    local wf="$1" inputs="${2:-{\}}" code
    for i in 1 2 3 4 5; do
        code=$(curl -sL -o /dev/null -w "%{http_code}" -X POST \
            -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
            "$API/actions/workflows/$wf/dispatches" \
            -d "{\"ref\":\"$BRANCH\",\"inputs\":$inputs}")
        [ "$code" = "204" ] && { log "dispatched $wf (attempt $i)"; return 0; }
        log "dispatch of $wf attempt $i -> $code"
        sleep 15
    done
    log "FATAL: could not dispatch $wf"
    return 1
}

newest_run() {   # newest_run <workflow file> <sha> -> "<id> <status> <conclusion> <run_number>"
    api "$API/actions/workflows/$1/runs?branch=$BRANCH&per_page=10" | python3 -c "
import json,sys
sha=sys.argv[1]
for r in json.load(sys.stdin).get('workflow_runs',[]):
    if r['head_sha']==sha:
        print(r['id'], r['status'], r['conclusion'] or '-', r['run_number'])
        break
" "$2" 2>/dev/null || echo ""
}

wait_for_run() {   # wait_for_run <run_id> -> prints the conclusion on stdout
    local run="$1" body status conclusion empty=0
    while :; do
        body=$(api "$API/actions/runs/$run")
        status=$(printf '%s' "$body" | jget "d.get('status','')")
        conclusion=$(printf '%s' "$body" | jget "d.get('conclusion') or ''")
        if [ -z "$status" ]; then
            # Network hiccup, not a completed run.
            empty=$((empty+1))
            [ "$empty" -gt 20 ] && die "gave up reading run $run"
            sleep 60
            continue
        fi
        empty=0
        printf '%s run %s: %s\n' "$(date -u +%H:%M:%S)" "$run" "$status" > "$HEARTBEAT"
        if [ "$status" = "completed" ]; then
            echo "$conclusion"
            return 0
        fi
        log "  run $run: $status, waiting"
        sleep 60
    done
}

save_job_logs() {   # save_job_logs <run_id> <label>
    local run="$1" label="$2" id
    for id in $(api "$API/actions/runs/$run/jobs" | python3 -c "
import json,sys
js=json.load(sys.stdin)
for j in js.get('jobs',[]):
    print(j['id'])
" 2>/dev/null); do
        local out="$DIR/$label-$run-$id.log"
        api "$API/actions/jobs/$id/logs" -o "$out"
        if [ -s "$out" ]; then
            log "log saved: $out"
            first_errors "$out"
        else
            rm -f "$out"
        fi
    done
}

# The first real error is the only part of a 3000-line log worth reading before
# deciding what to change, so it is printed where the failure is reported.
first_errors() {
    python3 - "$1" <<'PY' 2>/dev/null || true
import re, sys
try:
    lines = open(sys.argv[1], errors="replace").read().splitlines()
except OSError:
    sys.exit(0)
strip = lambda s: re.sub(r'^\S+Z\s+', '', s)
pat = re.compile(r'(error:|::error|FAILED|Results: |Failed: |missing |MISSING |Cannot find|no such file)', re.I)
hits = [strip(l) for l in lines if pat.search(l)]
for h in hits[:25]:
    print("   ", h[:220])
PY
}

run_url() { echo "https://github.com/$REPO/actions/runs/$1"; }

needs_fix() {   # needs_fix <target> <run> <log-ish>
    {
        echo "# Needs a fix: \`$1\`"
        echo
        echo "- commit: ${SHA}"
        echo "- run: $(run_url "$2")"
        echo "- logs: \`build/ci/overnight/\`"
        echo
        echo "The driver stopped here on purpose: deciding what a compile error means"
        echo "needs judgement, and re-running an unfixed stage only burns the night."
        echo "Read the log above the first error and fix that one thing."
    } > "$DIR/NEEDS_FIX.md"
    log "wrote $DIR/NEEDS_FIX.md"
}

# --- the two kinds of target ---------------------------------------------------
run_stage() {   # run_stage <stage> -> 0 green, 1 failed
    local stage="$1" run status conclusion
    local inflight_target inflight_run inflight_sha
    read -r inflight_target inflight_run inflight_sha < "$INFLIGHT" 2>/dev/null || true
    if [ "${inflight_target:-}" = "$stage" ] && [ "${inflight_sha:-}" = "$SHA" ]; then
        run="$inflight_run"
        status=$(api "$API/actions/runs/$run" | jget "d.get('status','')")
        if [ "$status" = "completed" ]; then
            log "the recorded run $run is already finished; starting fresh"
            rm -f "$INFLIGHT"; run=""
        else
            log "adopting the run already in flight: $run"
        fi
    fi
    if [ -z "${run:-}" ]; then
        dispatch stage.yml "{\"stage\":\"$stage\",\"runner\":\"macos-15\"}" || return 1
        sleep 40
        for i in 1 2 3 4 5 6; do
            read -r run status _ _ <<< "$(newest_run stage.yml "$SHA")"
            [ -n "${run:-}" ] && break
            sleep 15
        done
    fi
    [ -n "${run:-}" ] || { log "FATAL: could not find the dispatched run"; return 1; }
    echo "$stage $run $SHA" > "$INFLIGHT"
    log "run $run ($(run_url "$run"))"

    conclusion=$(wait_for_run "$run")
    log "run $run concluded: $conclusion"
    rm -f "$INFLIGHT"
    save_job_logs "$run" "$stage"

    if [ "$conclusion" = "success" ]; then
        echo "$stage $SHA" >> "$STATE"
        log "SUCCESS: $stage is green at ${SHA:0:7}"
        return 0
    fi
    log "failure recorded for $stage"
    needs_fix "$stage" "$run"
    return 1
}

run_build() {   # run_build -> 0 when the release with the IPAs exists
    local run status conclusion number tag sizes
    dispatch build.yml '{"heavy_toolchain":false}' || return 1
    sleep 45
    for i in 1 2 3 4 5 6; do
        read -r run status _ number <<< "$(newest_run build.yml "$SHA")"
        [ -n "${run:-}" ] && break
        sleep 15
    done
    [ -n "${run:-}" ] || { log "FATAL: could not find the dispatched build run"; return 1; }
    echo "build $run $SHA" > "$INFLIGHT"
    log "build run $run ($(run_url "$run")) -- both variants, then the release"
    conclusion=$(wait_for_run "$run")
    log "build run $run concluded: $conclusion"
    rm -f "$INFLIGHT"
    save_job_logs "$run" "build"
    if [ "$conclusion" != "success" ]; then
        log "the build failed; the failing job's log is above"
        needs_fix "build" "$run"
        return 1
    fi

    tag="build-$number"
    log "release $tag; collecting the assets"
    api "$API/releases/tags/$tag" | python3 - "$DIR" "$REPO" "$tag" <<'PY' 2>&1 | while read -r l; do log "$l"; done
import json, os, sys
d = sys.argv[1]; repo = sys.argv[2]; tag = sys.argv[3]
rel = json.load(sys.stdin)
assets = rel.get("assets", [])
lines = ["# IPAs are built", "",
         "Release: https://github.com/%s/releases/tag/%s" % (repo, tag), "",
         "| file | size | download |", "| --- | --- | --- |"]
ipas = [a for a in assets if a["name"].endswith(".ipa")]
for a in assets:
    lines.append("| %s | %.1f MB | %s |" % (a["name"], a["size"]/1e6, a["browser_download_url"]))
os.makedirs(os.path.join(d, "ipas"), exist_ok=True)
open(os.path.join(d, "IPA-READY.md"), "w").write("\n".join(lines) + "\n")
print("release %s has %d assets, %d of them IPAs" % (tag, len(assets), len(ipas)))
for a in ipas:
    print("  %s  %.1f MB  %s" % (a["name"], a["size"]/1e6, a["browser_download_url"]))
PY
    echo "build $SHA" >> "$STATE"
    log "SUCCESS: IPAs published. See $DIR/IPA-READY.md"
    return 0
}

# --- go ------------------------------------------------------------------------
for target in "${TARGETS[@]}"; do
    if grep -qx "$target $SHA" "$STATE" 2>/dev/null; then
        log "skip $target: already green at ${SHA:0:7}"
        continue
    fi
    log "=== target $target at ${SHA:0:7} ==="
    if [ "$target" = "build" ]; then
        run_build || die "stopping: 'build' needs a fix before it can produce IPAs"
    else
        run_stage "$target" || die "stopping: '$target' needs a fix before the next target can start"
    fi
done

log "every target in this chain is green at ${SHA:0:7}"
exit 0
