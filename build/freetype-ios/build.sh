#!/bin/bash
# Build freetype static for iOS arm64 — consumed by build/win32u-unix/build.sh,
# which compiles freetype_ios.c against these headers and merges
# build/libfreetype.a into libwin32u_unix.a (no Xcode project changes).
#
# Source: shallow clone of freetype 2.13.3 in research/freetype, at the tag the
# development machine used. The clone is made here when it is missing: the tree
# is a third-party checkout, not something this repository carries, and
# build/ntdll-unix and build/win32u-unix compile against
# research/freetype/include, so without it both fail on a missing ft2build.h.
# All optional deps disabled — fonts are plain TTFs from wine/fonts/.
set -e

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
SRC="$REPO_ROOT/research/freetype"
FREETYPE_TAG="VER-2-13-3"

if [ ! -d "$SRC" ]; then
    echo "=== cloning freetype $FREETYPE_TAG into research/freetype ==="
    mkdir -p "$REPO_ROOT/research"
    git clone --depth 1 --branch "$FREETYPE_TAG" \
        https://github.com/freetype/freetype.git "$SRC"
fi
test -f "$SRC/include/ft2build.h" || {
    echo "::error::$SRC/include/ft2build.h is missing; the freetype headers the Wine unix side compiles against are not there"
    exit 1
}
echo "    freetype $FREETYPE_TAG at $SRC"

cmake -S "$SRC" -B "$BUILD_DIR/build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
  -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
  -DCMAKE_C_FLAGS="-fno-stack-protector"

cmake --build "$BUILD_DIR/build" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
test -f "$BUILD_DIR/build/libfreetype.a" \
    || { echo "::error::libfreetype.a was not produced"; exit 1; }
echo "Done: $BUILD_DIR/build/libfreetype.a"
