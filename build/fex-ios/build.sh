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
if [ -f "$B/CMakeCache.txt" ] && { ! grep -q 'CMAKE_SYSTEM_PROCESSOR:.*=arm64' "$B/CMakeCache.txt" \
     || ! grep -q 'TUNE_CPU:.*=none' "$B/CMakeCache.txt" \
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
    cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
        -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DTUNE_CPU=none \
        -DCMAKE_C_FLAGS=-DFEX_IOS_HOST -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST
fi
cmake --build "$B" --target FEXCore FEXCore_Base
ls "$B/FEXCore/Source/"*.a
