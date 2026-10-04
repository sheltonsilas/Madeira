#!/bin/bash
# Configure the Wine tree that every iOS unix-side script compiles against.
#
# build/ntdll-unix, build/wineserver and build/win32u-unix all include
# `-include wine/build-macos/include/config.h` and add
# `-Iwine/build-macos/include`. On the development machine that tree existed;
# nothing in the repository created it, so on a clean checkout every one of
# those objects failed with "No such file or directory" for the forced include
# and only wg_parser_apple_ios -- the one file that deliberately has no Wine
# header -- compiled.
#
# What is actually needed from it:
#   * include/config.h and the rest of the generated include/ tree (configure
#     writes these; no compilation of Wine itself is required)
#   * tools/winebuild/winebuild and tools/widl, host executables that the PE
#     scripts call (`build/d3d11-triangle/build.sh`, and any future PE build in
#     this tree)
#
# So this configures, then builds only the host tools. It does not build Wine:
# the app's Wine side is compiled by the three iOS scripts, and the Windows PE
# modules come from wine/build-arm64ec, which build/wine-pe/build-ntdll.sh
# configures separately. Two trees on purpose -- build/wine-i386/build.sh says
# why in its own comment: reconfiguring one tree per arch would regenerate
# every module Makefile the unix-side build relies on.
#
# aarch64 (not arm64ec) because this tree is the "macOS" one: it is what builds
# the aarch64 PE test executables, and llvm-mingw provides that cross compiler.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
B="$R/wine/build-macos"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# Wine's configure rejects macOS's bison 2.3, and it is not a check that can be
# skipped: tools/widl/parser.c and tools/wrc/parser.c are generated from their .y
# files, so `make tools` really runs bison. See build/ci/ensure-bison.sh.
bash "$R/build/ci/ensure-bison.sh"
export PATH="$R/toolchains/bison-3.8.2/bin:$PATH"   # if it had to build one

# configure needs an aarch64 Windows cross compiler to resolve --enable-archs.
if [ -x "$TC/aarch64-w64-mingw32-gcc" ]; then
    export PATH="$TC:$PATH"
elif ! command -v aarch64-w64-mingw32-gcc >/dev/null 2>&1; then
    echo "::error::llvm-mingw not found at $TC; build.yml and stage.yml fetch it first"
    exit 1
fi

if [ ! -f "$B/config.status" ]; then
    echo "=== configuring wine/build-macos ==="
    mkdir -p "$B"
    # --without-freetype: dwrite's unix side is build/ntdll-unix/dwrite_freetype_ios.c
    #   and links the static freetype under research/freetype.
    # --without-gnutls: the crypto unixlibs link libgnutls from toolchains/gnutls-ios.
    # --without-vulkan: graphics go through DXMT; there is no wined3d backend.
    # --disable-tests, --without-x: no test suite and no X on a runner.
    # --enable-archs=aarch64: a Windows target, so configure wants a mingw; that
    #   is llvm-mingw, above. No GStreamer here: this tree exists for headers
    #   and host tools, and the gstreamer PE rule lives in build-arm64ec.
    (cd "$B" && ../configure --enable-archs=aarch64 --without-x --without-vulkan \
                             --without-freetype --without-gnutls --disable-tests)
fi

echo "=== host tools (makedep, widl, winebuild, wrc, wmc) ==="
bash "$R/build/ci/build-wine-tools.sh" "$B"

# config.h is what the iOS unix-side scripts force-include; assert it here so a
# missing tree is one clear line, not 36 unrelated compile failures.
test -f "$B/include/config.h" \
    || { echo "::error::wine/build-macos/include/config.h is missing"; exit 1; }
echo "=== wine/build-macos is ready ==="