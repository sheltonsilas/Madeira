#!/bin/bash
# Configure the wine/build-arm64ec tree, and do it identically everywhere.
#
# WHY THIS IS A SEPARATE SCRIPT
#
# Two places configured this tree: build/wine-pe/build-ntdll.sh and the
# "Configure the arm64ec Wine tree" step in stage.yml. They drifted, and the
# copy in stage.yml was the one missing flags -- so a stage run built a
# different tree than a full build.yml run did. One definition, called from
# both, removes that class of bug.
#
# WHY THE --enable-<program>=yes FLAGS EXIST AT ALL
#
# Wine disables most PE programs when the build host is not the PE target:
#
#   enable_services=${enable_services:-$HOST_ARCH}
#
# $HOST_ARCH is aarch64 on this runner, PE_ARCHS is arm64ec, and
# wine_fn_config_makefile disables any subdir whose enable value does not
# contain one of the PE archs. So services, wineboot, rpcss and conhost were
# dropped. Programs with no default at all -- explorer, start, taskmgr,
# regedit, notepad, winecfg -- hit a different clause that disables every
# programs/* subdir for arm64ec. Either way the target exists and the file
# simply is not built, which is why `make` reported "Nothing to be done for
# 'all'" instead of failing.
#
# cmd and msiexec default to "yes" and were the only two that built.
#
# NOTE the "=yes". A bare --enable-explorer assigns the EMPTY string, which
# lands in the same disabling clause it was meant to escape.
#
# These are exactly the programs an ordinary Windows application needs and a
# game does not -- the shell, the command interpreter, the installer and the
# configuration tools. See the header of build/wine-pe/build-universal.sh.
set -eu

R="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
B="$R/wine/build-arm64ec"

# macOS's bison 2.3 is rejected by Wine's configure, and this check cannot be
# skipped. See build/ci/ensure-bison.sh.
bash "$R/build/ci/ensure-bison.sh"
export PATH="$R/toolchains/bison-3.8.2/bin:$PATH"

TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
if [ ! -x "$TC/aarch64-w64-mingw32-gcc" ] && [ ! -x "$TC/arm64ec-w64-mingw32-gcc" ]; then
    echo "::error::llvm-mingw is not at $TC; fetch it before configuring"
    exit 1
fi
export PATH="$TC:$PATH"

# The general-purpose programs. Keep this list and the one in
# build/wine-pe/build-universal.sh in step: a program enabled here but absent
# there still fails the presence check.
PROGRAMS="explorer services wineboot start rpcss conhost taskmgr regedit notepad winecfg"
ENABLE_FLAGS=""
for p in $PROGRAMS; do
    ENABLE_FLAGS="$ENABLE_FLAGS --enable-$p=yes"
done

if [ ! -f "$B/config.status" ]; then
    echo "=== configuring wine/build-arm64ec ==="
    mkdir -p "$B"
    # --enable-winegstreamer keeps winegstreamer's PE rules although GStreamer
    # is absent (its unix side is build/ntdll-unix/winegstreamer_unixlib_ios.c).
    ( cd "$B" && ../configure --enable-archs=arm64ec --without-x \
        --disable-tests --enable-winegstreamer $ENABLE_FLAGS )
else
    echo "=== wine/build-arm64ec is already configured ==="
fi

# Every PE link uses winebuild and widl, and nothing builds them implicitly.
bash "$R/build/ci/build-wine-tools.sh" "$B"

echo "=== wine/build-arm64ec is ready ==="
echo "General-purpose programs enabled: $PROGRAMS"