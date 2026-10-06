#!/bin/bash
# Put a bison 3.0+ on PATH, or explain why that cannot be done.
#
# Wine's configure compiles a throwaway grammar to decide whether bison is
# "recent enough", and macOS ships 2.3, which fails that test:
#
#   configure: error: Your bison version is too old.
#   Please install bison version 3.0 or newer.
#
# This is not a check that can be skipped. tools/widl/parser.c, tools/wrc/parser.c
# and tools/wmc/mcy.c are not in the tree at all -- they are generated from their
# .y files, and this fork ships no tools/winebuild/parser.y but does ship the
# other grammars' sources -- so `make tools` genuinely runs bison. Every Wine
# tree needs it: wine/build-macos here, and wine/build-arm64ec in
# build/wine-pe/build-ntdll.sh.
#
# Homebrew has a bottle for this platform, so try that first. If it cannot be
# used, build GNU bison from the release tarball, pinned by SHA-256 like every
# other download in this repository. --disable-nls keeps it from needing the
# gettext tools, which are not on the image.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION=3.8.2
TARBALL_NAME="bison-$VERSION.tar.gz"
TARBALL_SHA256="06c9e13bdf7eb24d4ceb6b59205a4f67c2c7e7213119644430fe82fbd14a0abb"
TARBALL="$R/toolchains/$TARBALL_NAME"
PREFIX="$R/toolchains/bison-$VERSION"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

major() { bison --version 2>/dev/null | head -1 | sed 's/[^0-9]*\([0-9][0-9.]*\).*/\1/' | cut -d. -f1; }

if [ "$(major || echo 0)" -ge 3 ] 2>/dev/null; then
    echo "bison: $(bison --version | head -1)"
    exit 0
fi

echo "=== bison: $(bison --version 2>/dev/null | head -1 || echo none); Wine needs 3.0 or newer ==="

if command -v brew >/dev/null 2>&1; then
    echo "=== trying Homebrew ==="
    if brew install bison || brew upgrade bison; then
        # bison is keg-only, so brew does not symlink it into $(brew --prefix)/bin
        # -- which is exactly why this script kept falling through to the source
        # build and then to a host the runner cannot reach: the version check
        # below was still running macOS's bison 2.3. Homebrew prints the correct
        # PATH in as many words, so ask it where it put the formula.
        keg="$(brew --prefix bison 2>/dev/null || true)"
        [ -n "$keg" ] || keg="$(brew --prefix)/opt/bison"
        export PATH="$keg/bin:$PATH"
        hash -r 2>/dev/null || true
        if [ "$(major || echo 0)" -ge 3 ] 2>/dev/null; then
            echo "bison: $(bison --version | head -1)"
            exit 0
        fi
        echo "    Homebrew's bison is installed but still not on PATH"
    else
        echo "    Homebrew could not provide it; building from source instead"
    fi
fi

echo "=== building GNU bison $VERSION from source ==="
# A runner that cannot open one connection to ftp.gnu.org failed two consecutive
# runs at the fetch below, six attempts each, and --retry did not help: plain
# --retry covers HTTP errors and read timeouts, not a connection that was never
# established. These flags make one transient failure heal inside the job.
FETCH_FLAGS="--retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 30"
if [ ! -f "$TARBALL" ]; then
    # ftp.gnu.org is where this file lives, not the only place it lives, so try
    # it last and try two mirrors first. The pinned SHA-256 below is what makes
    # that safe: a mirror can only supply bytes that hash to the value already
    # committed here.
    for base in         "https://mirrors.kernel.org/gnu"         "https://ftpmirror.gnu.org"         "https://ftp.gnu.org/gnu"; do
        echo "    fetching $base/bison/$TARBALL_NAME"
        if curl -fSL $FETCH_FLAGS "$base/bison/$TARBALL_NAME" -o "$TARBALL"; then
            break
        fi
        rm -f "$TARBALL"
        echo "    $base did not answer"
    done
fi
[ -f "$TARBALL" ] || { echo "::error::no mirror served $TARBALL_NAME"; exit 1; }
echo "$TARBALL_SHA256  $TARBALL" | shasum -a 256 -c - \
    || { echo "::error::$TARBALL_NAME does not match the pinned SHA-256"; exit 1; }

SRC="$R/toolchains/bison-src"
rm -rf "$SRC" "$PREFIX"
mkdir -p "$SRC" "$PREFIX"
tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
# --disable-nls: gettext tools are not on the runner image and are not needed.
(cd "$SRC" && ./configure --prefix="$PREFIX" --disable-nls >/dev/null && make -j "$JOBS" >/dev/null && make install >/dev/null)
rm -rf "$SRC"

export PATH="$PREFIX/bin:$PATH"
hash -r 2>/dev/null || true
if [ "$(major || echo 0)" -lt 3 ] 2>/dev/null; then
    echo "::error::bison $VERSION built into $PREFIX is still not usable"
    exit 1
fi
echo "bison: $(bison --version | head -1) (built into toolchains/bison-$VERSION)"