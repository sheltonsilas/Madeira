#!/bin/bash
# Build the archive the app actually links: libdxmt_combined.a.
#
# dxmt-ios/build.sh produces libdxmt_unix.a (DXMT's unix/Metal side plus
# airconv, whose objects call into LLVM), and it only refreshes an *existing*
# libdxmt_combined.a because on the development machine that file was made by
# hand. A clean checkout has neither, so the merge has to be written down:
# the app's Frameworks phase links libdxmt_combined.a and fails without it.
#
# Why one archive rather than two: airconv and LLVM's archives are built from
# the same LLVM headers and are only ever used together, and a single archive
# keeps the app's link line from having to name 30 LLVM libraries in the right
# order.
#
# Inputs:  build/dxmt-ios/libdxmt_unix.a      (build/dxmt-ios/build.sh)
#          toolchains/llvm-ios-build/lib/*.a   (build/ci/build-llvm-ios.sh)
# Output:  app/Madeira/libdxmt_combined.a
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The archive lives next to the script that makes it: build.sh sets
# OUT_LIB="$BUILD_DIR/libdxmt_unix.a" with BUILD_DIR=build/dxmt-ios. This line
# said dxmt/build-ios/libdxmt_unix.a, which is where nothing has ever written
# it, so a build.yml run compiled all 87 objects, archived them successfully
# and then failed here: "missing .../dxmt/build-ios/libdxmt_unix.a - run
# build/dxmt-ios/build.sh first". The old path is still accepted so a tree
# laid out by hand (the development machine's, before this script existed)
# keeps working, but the canonical one is tried first.
DYMT_UNIX="$R/build/dxmt-ios/libdxmt_unix.a"
[ -f "$DYMT_UNIX" ] || DYMT_UNIX="$R/dxmt/build-ios/libdxmt_unix.a"
LLVM_LIB="$R/toolchains/llvm-ios-build/lib"
OUT="$R/app/Madeira/libdxmt_combined.a"

test -f "$DYMT_UNIX" || {
    echo "::error::missing the dxmt unix archive (looked in build/dxmt-ios/ and dxmt/build-ios/) - run build/dxmt-ios/build.sh first" >&2
    exit 1
}
test -d "$LLVM_LIB" || {
    echo "::error::missing $LLVM_LIB - run build/ci/build-llvm-ios.sh first" >&2
    exit 1
}
# Every LLVM archive in the iOS build, not the 33 names DXMT's meson build
# lists: that list mentions LLVMObjCARCOpts, which no longer exists as its own
# library in LLVM 15, and omits whatever it now depends on instead. Merging the
# whole set is both simpler and correct -- a static archive only contributes the
# members that resolve something.
set -- "$LLVM_LIB"/libLLVM*.a
test -f "$1" || { echo "::error::no libLLVM*.a in $LLVM_LIB" >&2; exit 1; }
echo "=== merging $(($#)) LLVM archives + libdxmt_unix.a ==="

rm -f "$OUT"
# libtool, not ar: it merges archives member by member and keeps the symbol
# tables consistent, which plain `ar rcs` on a concatenation does not.
xcrun libtool -static -o "$OUT" "$DYMT_UNIX" "$@"
xcrun ranlib "$OUT"

echo "=== Built: $OUT ($(du -h "$OUT" | cut -f1)) ==="
# A combined archive smaller than the unix side means the merge dropped members.
unix_size=$(wc -c < "$DYMT_UNIX")
out_size=$(wc -c < "$OUT")
test "$out_size" -ge "$unix_size" || {
    echo "::error::the combined archive is smaller than its input; the merge lost members" >&2
    exit 1
}
# The app's link will look for airconv's LLVM symbols here. Check one directly
# rather than trusting the size.
if command -v nm >/dev/null; then
    nm -gU "$OUT" 2>/dev/null | grep -q 'llvm' \
        || echo "::warning::no llvm symbols found in $OUT; airconv may be unlinked"
fi
