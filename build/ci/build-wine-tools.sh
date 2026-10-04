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
#
# makedep is the binary tools/makedep in a BUILD tree: tools/makedep/ is a
# directory in the source tree, and configure's generated Makefile links the
# program straight into tools/. Checking the directory-shaped path reports it
# missing when it was just built.
missing=0
check() {   # check <label> <path>
    if [ -x "$2" ]; then
        echo "    ok $1"
    else
        echo "    MISSING $1"
        missing=$((missing + 1))
    fi
}
check tools/makedep "$B/tools/makedep"
check tools/widl/widl "$B/tools/widl/widl"
check tools/winebuild/winebuild "$B/tools/winebuild/winebuild"
check tools/wrc/wrc "$B/tools/wrc/wrc"
if [ "$missing" -gt 0 ]; then
    echo "::error::$missing Wine host tool(s) did not build in $B"
    exit 1
fi
echo "=== Wine host tools are ready in $B ==="