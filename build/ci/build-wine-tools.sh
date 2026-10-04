#!/bin/bash
# Build the Wine host tools a configured Wine tree needs before anything else:
# makedep first, then widl (which turns .idl into headers), then winebuild (which
# links every PE module), then wrc and wmc.
#
# Why this exists rather than `make tools`: in this Wine version the top-level
# `tools` target has no prerequisites, so `make -C <tree> tools` prints
# "Nothing to be done" and builds nothing at all. The tools are recursive-make
# targets, one directory each.
#
# Usage: build/ci/build-wine-tools.sh <configured-tree-dir>
set -euo pipefail

B="${1:-}"
if [ -z "$B" ] || [ ! -d "$B" ]; then
    echo "usage: $0 <configured-wine-build-dir>" >&2
    exit 2
fi
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

test -f "$B/include/config.h" || {
    echo "::error::$B/include/config.h is missing; configure did not run"
    exit 1
}

for d in tools tools/widl tools/winebuild tools/wrc tools/wmc; do
    if [ ! -f "$B/$d/Makefile" ]; then
        echo "    $d: no generated Makefile, skipping"
        continue
    fi
    echo "=== $d ==="
    make -C "$B/$d" -j "$JOBS"
done

# The tools are what everything else in this tree depends on, so report exactly
# which are missing rather than letting the next step fail on a link error.
missing=0
for f in tools/makedep/makedep tools/widl/widl tools/winebuild/winebuild tools/wrc/wrc; do
    if [ -x "$B/$f" ]; then
        echo "    ok $f"
    else
        echo "    MISSING $f"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -gt 0 ]; then
    echo "::error::$missing Wine host tool(s) did not build in $B"
    exit 1
fi
echo "=== Wine host tools are ready in $B ==="