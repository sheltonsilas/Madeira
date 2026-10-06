#!/bin/bash
# Configure (first time) and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"

# FEX's CMake runs Scripts/aarch64_fit_native.py, which does
# `from pkg_resources import parse_version` -- setuptools, which is not installed
# for the runner's Python 3.13. The script dies, CMake captures nothing from it,
# and configure then fails two lines later with "string sub-command STRIP
# requires two arguments", which points nowhere near the cause. Install
# setuptools for the interpreter FEX is about to call.
#
# setuptools alone is not enough. TUNE_CPU defaults to "native" (FEX's
# CMakeLists.txt), and that path feeds /proc/cpuinfo to the same script. There is
# no /proc/cpuinfo on macOS, so the script dies again and configure fails with
# the identical STRIP error even when pkg_resources imports cleanly. TUNE_CPU=none
# is the sentinel that skips the CPU probe altogether; the iOS FEXCore build is
# not tuned to the host, which is correct here anyway. build/fex-wow64/build.sh
# passes the same flag for the same reason.
#
# FEX_IOS_HOST is defined by the caller, never by FEX's own CMakeLists: only the
# FEX_IOS_HOST_BUILD option lives there, and that one controls the 32-bit guest
# window for the WOW64 module, not this macro. Without FEX_IOS_HOST the
# iOS-Madeira declarations in FEXCore's Core.cpp are compiled out while their
# uses are not -- those uses sit outside every #ifdef, so the file only compiles
# with the macro on. Define it on the C, C++ and ASM lines, as
# fex-wow64/build.sh does. FEX_IOS_HOST_BUILD is deliberately NOT set: this is
# the aarch64 host build, which does not want the guest window.
echo "=== pkg_resources (setuptools) for FEX's configure scripts ==="
python3 - <<'PY'
import subprocess, sys
try:
    import pkg_resources  # noqa: F401
    print("    already present")
    sys.exit(0)
except ImportError:
    pass
for extra in ([], ["--break-system-packages"]):
    args = [sys.executable, "-m", "pip", "install", "--user", "setuptools<82"] + extra
    if subprocess.run(args).returncode == 0:
        print("    installed")
        sys.exit(0)
sys.exit("    FAILED to install setuptools")
PY
# A configure that died before finishing still leaves a CMakeCache.txt behind
# (the processor failure above did exactly that), and the guard would then skip
# reconfiguring and fail later for a confusing reason. Throw away any cache that
# does not already carry the arm64 processor, or that predates -DTUNE_CPU=none:
# CMake only reads the option cache entries at configure time, so an inherited
# cache would silently pin TUNE_CPU back to "native" and drop the FEX_IOS_HOST
# define, and the flags below would then do nothing on the next run.
# ENABLE_FEX_ALLOCATOR is in this guard for the same reason as the other three,
# and it is the one that actually bit: CI caches FEX/build-ios under a key built
# from hashFiles('FEX/CMakeLists.txt', 'docs/BUILDING.md') -- not from this
# script. So flipping the flag below without invalidating that cache restores a
# CMakeCache.txt that still says OFF, the guard skips the reconfigure, and the
# build silently keeps the old configuration while the log says nothing. CMake
# reads option entries only at configure time.
if [ -f "$B/CMakeCache.txt" ] && { ! grep -q 'CMAKE_SYSTEM_PROCESSOR:.*=arm64' "$B/CMakeCache.txt" \
     || ! grep -q 'TUNE_CPU:.*=none' "$B/CMakeCache.txt" \
     || ! grep -q 'ENABLE_FEX_ALLOCATOR:.*=ON' "$B/CMakeCache.txt" \
     || ! grep -q 'CXX_FLAGS.*FEX_IOS_HOST' "$B/CMakeCache.txt"; }; then
    echo "=== stale or untuned CMakeCache; reconfiguring ==="
    rm -rf "$B"
fi
if [ ! -f "$B/CMakeCache.txt" ]; then
    # CMAKE_SYSTEM_PROCESSOR must be given explicitly. Some CMake versions
    # leave it unset for -DCMAKE_SYSTEM_NAME=iOS, and FEX's CMakeLists.txt does
    # `string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)`, which then fails
    # with "string no output variable specified" and reports the unhelpful
    # "Unsupported processor type". Verified: this is what CI hit.
    # ENABLE_FEX_ALLOCATOR=ON, matching build/fex-arm64ec/build.sh. It was OFF
    # here, and that was the whole of one of the two remaining link failures: it
    # gates `add_subdirectory(External/rpmalloc/)` in FEX/CMakeLists.txt, and
    # that submodule is where ios_fex_band_base, ios_fex_band_end and
    # rpm_cas_snapshot_take are defined -- while Core.cpp:1971 calls
    # rpm_cas_snapshot_take with no guard at all, and AllocatorHooks.cpp's
    # IosRpmGuard needs fex_ios_rpm_lock/unlock from the same file. The source
    # states the intended invariant itself, beside those globals: they live there
    # "purely so that every FEX binary that links FEXCore" has them. So
    # links-FEXCore implies links-rpmalloc, and OFF broke it.
    # (JemallocLibs' #else branch does keep the Allocator functions working with
    # OFF, which is why those five symbols cleared separately -- with ON they
    # simply route through rpmalloc instead of posix_memalign.)
    #
    # ⛔ NOTHING may sit between the `cmake` line and its last argument. A comment
    # there is not harmless: the backslash-newline joins the lines first, then the
    # `#` begins a word, and bash drops the REST OF THE COMMAND as a comment -- so
    # every argument after it is silently never passed. That is exactly how this
    # change first shipped. The paragraph above sat between
    # -DBUILD_FEX_LINUX_TESTS=OFF and -DENABLE_FEX_ALLOCATOR=ON, which dropped both
    # -DENABLE_FEX_ALLOCATOR=ON and -DTUNE_CPU=none; the run then died in FEX's
    # configure on a missing /proc/cpuinfo because TUNE_CPU had silently gone back
    # to "native". `bash -n` accepts it -- it is valid syntax -- so nothing but a
    # real configure catches it.
    cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
        -DENABLE_FEX_ALLOCATOR=ON -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DTUNE_CPU=none \
        -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST
fi
# JemallocLibs is the third archive the app links, and it is the only definition of
# FEXCore::Allocator::malloc/free/memalign/aligned_alloc/aligned_free in the whole
# tree (FEX/FEXCore/Source/Utils/AllocatorHooks.cpp). FEX declares that target
# unconditionally -- it is not inside the APPLE branch that disables jemalloc and
# rpmalloc -- so the `ld: library 'JemallocLibs' not found` failure was this line,
# not a stale project reference. Building only FEXCore and FEXCore_Base left the
# archive absent, and the next link then failed on five undefined Allocator symbols.
#
# rpmalloc is listed as well as JemallocLibs. JemallocLibs declares
# `target_link_libraries(JemallocLibs PUBLIC rpmalloc)`, so building it does
# build rpmalloc first, but naming it here makes the archive this script is
# expected to leave behind explicit -- the app links librpmalloc.a directly,
# because a static library's transitive dependency does not survive into
# Xcode's link line.
cmake --build "$B" --target FEXCore FEXCore_Base JemallocLibs rpmalloc
ls "$B/FEXCore/Source/"*.a
ls "$B/External/rpmalloc/"*.a 2>/dev/null || true
