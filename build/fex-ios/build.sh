#!/bin/bash
# Configure (first time) and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"
# A configure that died before finishing still leaves a CMakeCache.txt behind
# (the processor failure above did exactly that), and the guard would then skip
# reconfiguring and fail later for a confusing reason. Throw away any cache that
# does not already carry the arm64 processor.
if [ -f "$B/CMakeCache.txt" ] && ! grep -q 'CMAKE_SYSTEM_PROCESSOR:.*=arm64' "$B/CMakeCache.txt"; then
    echo "=== stale CMakeCache without an arm64 processor; reconfiguring ==="
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
        -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON
fi
cmake --build "$B" --target FEXCore FEXCore_Base
ls "$B/FEXCore/Source/"*.a
