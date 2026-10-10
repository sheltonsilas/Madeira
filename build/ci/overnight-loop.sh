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
# and the published release -- and then reports where they are. The single word
# `chain` walks every stage that is not green at this commit, then `build`.
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
#   <target>-<run>.log, NEEDS_FIX.md, IPA-READY.md
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
NEEDS_FIX_MARK="$DIR/NEEDS_FIX.md.tmp"
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

# --- the commit being driven is the branch tip, not whatever is checked out --
#
# The workflows check out the branch, so the commit a run builds is the tip of
# it. Driving local HEAD instead meant a run could be dispatched (and its log
# read) as though it contained commits that were never pushed -- which is how a
# fix appears to have no effect. Local HEAD not being the tip is therefore an
# error: push (or stash) before driving. Uncommitted changes to this directory
# are harmless, since this script is read from disk and never runs on a runner.
LOCAL_SHA="$(git -C "$R" rev-parse HEAD)"
SHA="$(api "$API/branches/$BRANCH" | jget "d['commit']['sha']")"
[ -n "$SHA" ] || die "could not read the branch head (network?)"
if [ "$LOCAL_SHA" != "$SHA" ]; then
    die "HEAD ($LOCAL_SHA) is not the tip of $BRANCH ($SHA); the workflows build the branch tip, so push first"
fi
log "driving ${TARGETS[*]} at ${SHA:0:7}"

# --- dispatch -----------------------------------------------------------------
dispatch () {   # dispatch <workflow file> [json input object]
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

# newest_any_run <workflow file> -> "<id> <status> <conclusion> <run_number> <sha>"
#
# Used to find runs nobody dispatched through this driver. build.yml triggers on
# every push, and its concurrency group cancels the previous push's run, so the
# newest run of that workflow is not necessarily the newest one *this script*
# started. A driver that matched on the local commit alone adopted a run that had
# already been cancelled and reported the build as failed without waiting for
# anything.
newest_any_run() {
    api "$API/actions/workflows/$1/runs?branch=$BRANCH&per_page=10" | python3 -c "
import json,sys
rs=json.load(sys.stdin).get('workflow_runs',[])
if rs:
    r=rs[0]
    print(r['id'], r['status'], r['conclusion'] or '-', r['run_number'], r['head_sha'])
" 2>/dev/null || echo ""
}

run_meta() {   # run_meta <run_id> -> "<status> <conclusion> <run_number> <head_sha>"
    api "$API/actions/runs/$1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('status',''), d.get('conclusion') or '-', d.get('run_number',''), d.get('head_sha',''))
" 2>/dev/null || echo ""
}

in_flight_any_run() {   # newest run of a workflow that has not completed yet
    local id
    read -r id _ _ _ _ <<< "$(newest_any_run "$1")"
    [ -n "${id:-}" ] || return 0
    local status
    status=$(api "$API/actions/runs/$id" | jget "d.get('status','')")
    [ "$status" != "completed" ] && echo "$id"
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

RUN_LOGS=()

save_job_logs() {   # save_job_logs <run_id> <label>
    local run="$1" label="$2" id
    RUN_LOGS=()
    for id in $(api "$API/actions/runs/$run/jobs" | python3 -c "
import json,sys
js=json.load(sys.stdin)
for j in js.get('jobs',[]):
    print(j['id'])
" 2>/dev/null); do
        local out="$DIR/$label-$run-$id.log"
        local got=0 attempt
        for attempt in 1 2 3 4 5; do
            api "$API/actions/jobs/$id/logs" -o "$out" || true
            # GitHub answers a log request it cannot serve with a two-line XML
            # blob (BlobNotFound) rather than an HTTP error, so asking whether the
            # file arrived accepted that blob as the log: no infrastructure
            # signature in it, so the loop declined to retry a network failure it
            # had every reason to retry. Accept the payload only if it looks like
            # a runner log -- not XML, not JSON, and long enough to be one.
            if [ -s "$out" ] && [ "$(wc -l < "$out")" -ge 5 ]                 && ! head -c 16 "$out" | grep -aqE '<[?]xml|[{]'; then
                got=1
                break
            fi
            rm -f "$out"
            sleep $((attempt * 5))
        done
        if [ "$got" = 1 ]; then
            RUN_LOGS+=("$out")
            log "log saved: $out"
            first_errors "$out"
        else
            log "WARNING: could not fetch the log for job $id in 5 attempts;"
            log "WARNING: the retry decision below will be made without it"
        fi
    done
}

# A failure that is not about the code: a download, a DNS lookup, a starved
# runner. One such run cost a cycle tonight -- the bison bottle download failed
# and the run died in a precondition step, which the driver recorded as "the
# stage is broken". Retrying those once is worth it; retrying anything else is
# not, because a compile error retried is still a compile error, and pretending
# otherwise is how a real fault gets buried under three identical logs.
infra_flake() {
    local f hit=0
    for f in "${RUN_LOGS[@]:-}"; do
        [ -f "$f" ] || continue
        if grep -aqiE 'curl: \(|Failed to connect|Could not resolve|Connection reset|Operation timed out|remote end hung up|502 Bad Gateway|503 Service|429 Too Many|Rate limit|Network is unreachable|Resource temporarily unavailable' "$f"; then
            hit=1
            log "  infrastructure signature in $(basename "$f")"
        fi
    done
    [ "$hit" = 1 ]
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

needs_fix() {   # needs_fix <target> <run>
    {
        echo "# Needs a fix: \`$1\`"
        echo
        echo "- commit: ${SHA}"
        echo "- run: $(run_url "$2")"
        echo "- logs: \`build/ci/overnight/\`"
        echo
        if [ "${RETRIED_FOR_INFRA:-0}" = "1" ]; then
            echo "The first failure of this target looked like infrastructure, so it was"
            echo "retried once. This note is from the retry, which failed the same way --"
            echo "so read it as a real defect now."
        else
            echo "The driver stopped here on purpose: deciding what a compile error means"
            echo "needs judgement, and re-running an unfixed stage only burns the night."
            echo "Read the log above the first error and fix that one thing."
        fi
    } > "$NEEDS_FIX_MARK"
    mv -f "$NEEDS_FIX_MARK" "$DIR/NEEDS_FIX.md"
    log "wrote $DIR/NEEDS_FIX.md"
}

# --- the two kinds of target ---------------------------------------------------
run_stage () {   # run_stage <stage> -> 0 green, 1 failed (one retry if it was infrastructure)
    local attempt
    for attempt in 1 2; do
        if stage_once "$1"; then return 0; fi
        if [ "$attempt" = 1 ] && infra_flake; then
            log "retrying $1 once: that failure was infrastructure, not code"
            rm -f "$NEEDS_FIX_MARK"
            RETRIED_FOR_INFRA=1
            continue
        fi
        return 1
    done
}

stage_once() {
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

run_build () {   # run_build -> 0 when the release with the IPAs exists
    local attempt
    for attempt in 1 2; do
        if build_once; then return 0; fi
        if [ "$attempt" = 1 ] && infra_flake; then
            log "retrying the build once: that failure was infrastructure, not code"
            rm -f "$NEEDS_FIX_MARK"
            RETRIED_FOR_INFRA=1
            continue
        fi
        return 1
    done
}

build_once() {
    local run status conclusion number tag candidate_sha

    # Adopt a run that is already in flight before dispatching anything. Two
    # reasons: this workflow triggers on every push, so a run may already be
    # building this commit; and dispatching another one would *cancel* it, since
    # build.yml's concurrency group is per-ref with cancel-in-progress. That is
    # how a driver restart threw away a healthy run.
    run="$(in_flight_any_run build.yml)"
    if [ -n "$run" ]; then
        read -r status conclusion number _ <<< "$(run_meta "$run")"
        candidate_sha=$(api "$API/actions/runs/$run" | jget "d.get('head_sha','')")
        if [ "$candidate_sha" != "$SHA" ]; then
            # An older commit's run. build.yml's concurrency group will cancel it
            # the moment a run for this tip is dispatched, and waiting for a build
            # of code we are not driving would be busywork.
            log "a build run for ${candidate_sha:0:7} is in flight; ignoring it (this driver is at ${SHA:0:7})"
            run=""
        else
            log "a build run is already in flight: $run (adopting it)"
        fi
    fi
    if [ -z "${run:-}" ]; then
        # A run that already succeeded for this commit is the answer, not work
        # to repeat -- that is what makes a driver restart cheap.
        read -r run status conclusion number <<< "$(newest_run build.yml "$SHA")"
        if [ "${conclusion:-}" = "success" ]; then
            log "build is already green at ${SHA:0:7} (run $run)"
            report_release "$number" || return 1
            echo "build $SHA" >> "$STATE"
            return 0
        fi
        run=""
        dispatch build.yml '{"heavy_toolchain":false}' || return 1
        sleep 45
        for i in 1 2 3 4 5 6; do
            read -r run status _ number <<< "$(newest_run build.yml "$SHA")"
            [ -n "${run:-}" ] && break
            sleep 15
        done
    fi
    [ -n "${run:-}" ] || { log "FATAL: could not find the dispatched build run"; return 1; }
    echo "build $run $SHA" > "$INFLIGHT"
    log "build run $run ($(run_url "$run")) -- both variants, then the release"
    conclusion=$(wait_for_run "$run")
    log "build run $run concluded: $conclusion"
    rm -f "$INFLIGHT"
    save_job_logs "$run" "build"

    if [ "$conclusion" = "cancelled" ]; then
        # Almost always a push of a newer commit: concurrency cancels the older
        # run. Say so, and let the caller decide whether to drive the new tip.
        log "run $run was superseded (cancelled). Re-run this driver for the new tip"
        return 1
    fi
    if [ "$conclusion" != "success" ]; then
        log "the build failed; the failing job's log is above"
        needs_fix "build" "$run"
        return 1
    fi

    report_release "$number" || return 1
    echo "build $SHA" >> "$STATE"
    log "SUCCESS: IPAs published. See $DIR/IPA-READY.md"
    return 0
}

report_release() {   # report_release <run_number> -> 0 when the IPAs are on a published release
    local number="$1" tag n
    tag="build-$number"
    log "release $tag; collecting the assets"
    api "$API/releases/tags/$tag" -o "$DIR/release-$tag.json"
    n=$(python3 - "$DIR" "$REPO" "$tag" "$DIR/release-$tag.json" <<'PY' 2>/dev/null
import json, os, sys
d, repo, tag, path = sys.argv[1:5]
try:
    rel = json.load(open(path))
except Exception:
    print(0); raise SystemExit
assets = rel.get("assets", [])
ipas = [a for a in assets if a["name"].endswith(".ipa")]
lines = ["# IPAs are built", "",
         "Release: https://github.com/%s/releases/tag/%s" % (repo, tag), "",
         "| file | size | download |", "| --- | --- | --- |"]
for a in assets:
    lines.append("| %s | %.1f MB | %s |" % (a["name"], a["size"] / 1e6, a["browser_download_url"]))
os.makedirs(os.path.join(d, "ipas"), exist_ok=True)
open(os.path.join(d, "IPA-READY.md"), "w").write("\n".join(lines) + "\n")
open(os.path.join(d, "ipas.txt"), "w").write("\n".join(
    "%s  %.1f MB  %s" % (a["name"], a["size"] / 1e6, a["browser_download_url"]) for a in ipas) + "\n")
print(len(ipas))
PY
)
    [ -n "${n:-}" ] || n=0
    if [ "$n" -gt 0 ]; then
        while read -r l; do [ -n "$l" ] && log "  $l"; done < "$DIR/ipas.txt"
        log "SUCCESS: $n IPA(s) published; see $DIR/IPA-READY.md"
        return 0
    fi
    # The release exists but carries no IPA, which means the publish job did not
    # get both artifacts; that is a real failure and this target is not done.
    log "the release has no IPA assets; the publish job must have failed"
    return 1
}

# --- nightly chain ----------------------------------------------------------
# Walks the stages that are not yet green at this commit, then dispatches the
# full build.yml so the IPAs come out of the last run.  Each stage is persisted
# into STATE once it is green, so a resumed invocation picks up where the
# previous one stopped.
_run_chained() {
    local todo=() s
    for s in wine-unix wine-pe wine-pe-universal dxmt-ios rppairing-ios xcodebuild build; do
        case "$s" in
        dxmt-ios)
            if grep -qE "^dxmt-ios( |/)" "$STATE" 2>/dev/null; then
                log "[chain] dxmt-ios already green; skip"
                continue
            fi
            ;;
        *)
            if grep -q "^$s " "$STATE" 2>/dev/null; then
                log "[chain] $s already green; skip"
                continue
            fi
            ;;
        esac
        todo+=("$s")
    done

    if [ ${#todo[@]} -eq 0 ]; then
        log "[chain] every stage is already green; go straight to build.yml"
    fi

    for s in "${todo[@]}"; do
        log "[chain] ---- $s ----"
        if [ "$s" = "build" ]; then
            run_build || return 1
        else
            run_stage "$s" || return 1
        fi
    done
    return 0
}
# --- go ------------------------------------------------------------------------
if [ "${TARGETS[0]:-}" = "chain" ]; then
    log "chain mode: walking every stage not yet green at ${SHA:0:7}"
    _run_chained || die "stopping: a target in the chain needs a fix before the next one can start"
    log "the chain is complete at ${SHA:0:7}"
    exit 0
fi

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
