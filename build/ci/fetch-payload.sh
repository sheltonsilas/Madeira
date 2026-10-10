#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# fetch-payload.sh - bring a prebuilt payload into the workspace.
#
# WHY PAYLOADS EXIST AT ALL
# Two things the app must ship cannot be produced inside the app build:
#
#   i386-windows.tar.gz      the 32-bit Windows farm (docs/WOW64.md, "Building")
#   qemu-ios-tci-arm64.tar.gz  the QEMU sysroot (docs/LINUX_ENGINE.md)
#
# Both take tens of minutes to an hour and both are pure functions of a pinned
# submodule revision. Building them on every app build would push build.yml past
# its timeout and make every fix cycle slower, and a normal GitHub workflow
# artifact cannot be read from another repository, which is where the app build
# runs. So they are built by `payloads.yml` (dispatch only), published as assets
# of one rolling release, and downloaded here.
#
# The rolling release, not a per-run tag: the app build wants "the current
# farm", not "the farm from run 42". One tag, replaced in place.
#
# EXIT CODES, AND WHY THERE ARE THREE
#   0   the payload is in place
#   10  the payload has not been published (yet). This is NOT an error: an app
#       build before the first payload run must still produce an IPA, just one
#       without that feature. Every caller treats 10 as "warn and continue", so
#       the payload pipeline can be brought up without freezing the app build.
#   1   something else went wrong (bad arguments, network failure, a corrupt
#       archive). A caller must NOT swallow this: a truncated download that
#       extracts to an empty directory looks exactly like a missing feature and
#       would ship silently.
#
# usage: fetch-payload.sh <asset-name> <destination-directory>
#   e.g. fetch-payload.sh i386-windows.tar.gz app/Madeira/i386-windows
#
# env:
#   PAYLOAD_REPO  owner/name holding the rolling release.
#                 Defaults to the repository the workflow runs in, so the same
#                 script works in the fork (Actions on) and the build host.
#   PAYLOAD_TAG   the rolling release's tag. Default: payloads.
#   GH_TOKEN      optional; raises the API rate limit and is required if the
#                 release is ever made private.

set -euo pipefail

ASSET="${1:-}"
DEST="${2:-}"
if [ -z "$ASSET" ] || [ -z "$DEST" ]; then
    echo "usage: fetch-payload.sh <asset-name> <destination-directory>" >&2
    exit 1
fi

REPO="${PAYLOAD_REPO:-${GITHUB_REPOSITORY:-sheltonsilas/madeira-ci}}"
TAG="${PAYLOAD_TAG:-payloads}"

echo "payload: $ASSET -> $DEST (release $TAG of $REPO)"

api() {
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$@"
    else
        curl -fsSL "$@"
    fi
}

# Does the asset exist? The release is fetched once and searched by name, rather
# than building the asset URL by guesswork: a release asset's download URL
# carries its numeric id, not its name.
asset_id=$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG" 2>/dev/null \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
name = sys.argv[1]
for a in data.get('assets', []):
    if a.get('name') == name:
        print(a['id'])
        break
" "$ASSET" || true)

if [ -z "$asset_id" ]; then
    # Distinguish "no such release/asset" from "the API is unreachable". Both
    # land here, so say what is missing and which repo was asked, and let the
    # caller decide; 10 means continue without the feature.
    echo "::warning::$ASSET is not published in $REPO@$TAG; continuing without it"
    exit 10
fi

# A payload is tens to hundreds of megabytes, so download to a file and only
# then extract: `curl | tar` would report success for a short download, and the
# resulting half-populated directory is invisible until a program fails to load.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading asset $asset_id ..."
api -L -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/$REPO/releases/assets/$asset_id" -o "$tmp/$ASSET"

size=$(wc -c < "$tmp/$ASSET" | tr -d ' ')
echo "downloaded $(du -h "$tmp/$ASSET" | cut -f1) ($size bytes)"
[ "$size" -gt 1024 ] || { echo "::error::$ASSET is only $size bytes - the download is truncated"; exit 1; }

mkdir -p "$DEST"
tar -xzf "$tmp/$ASSET" -C "$DEST"

# A payload that extracted nothing is the failure this whole script is shaped to
# avoid: it would look exactly like a feature that is switched off.
n=$(find "$DEST" -type f ! -name '.gitkeep' | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then
    echo "::error::$ASSET extracted no files into $DEST"
    exit 1
fi
echo "payload in place: $n file(s) in $DEST"
