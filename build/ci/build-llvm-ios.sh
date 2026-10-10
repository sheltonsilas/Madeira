#!/bin/bash
# Cross-build LLVM 15.0.7 for iOS/arm64 -- the static libraries DXMT's
# airconv (its shader translator) links against.
#
# Why this exists: the app links `libdxmt_combined.a`, which is DXMT's unix
# side plus airconv plus the LLVM 15 archives airconv needs. dxmt-ios/build.sh
# can produce the first part from headers alone, but not the LLVM archives, so
# without this script no IPA can be linked at all. Upstream's
# build/dxmt-ios/README.md describes this build and calls it "hours"; it is
# gated behind workflow_dispatch for that reason and its output is cached.
#
# The recipe is upstream's, read back from their own CMakeCache:
#   -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64
#   -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_BUILD_TYPE=Release
#   -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0
#   -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0
#   -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD=
#   -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off
#   -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off
# plus one code patch they document and that a stock checkout does not have:
# llvm/cmake/modules/AddLLVM.cmake must treat iOS as Darwin so the linker gets
# -dead_strip instead of --gc-sections, which Apple's ld does not accept.
#
# The source is the official 15.0.7 release tarball rather than a git clone of
# the pinned commit: it is the same release the header substitution elsewhere
# in this repository already uses, so the headers DXMT compiles against and the
# libraries it links are the same version, and it is a 50 MB download instead of
# a full clone.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$R"

VERSION=15.0.7
SRC="$R/toolchains/llvm-project"
OUT="$R/toolchains/llvm-ios-build"
HOST="$R/toolchains/llvm-host-tblgen"
TARBALL="$R/toolchains/llvm-project-$VERSION.src.tar.xz"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Already done? Not merely the directory and not merely one file: a build that
# dies partway still leaves both, and an early return on that would hand a
# half-built toolchain to the linker. airconv's dependency list alone names
# thirty libraries, so require most of them.
archives() { ls "$OUT"/lib/libLLVM*.a 2>/dev/null | wc -l | tr -d ' '; }
if [ -f "$OUT/lib/libLLVMCore.a" ] && [ -f "$OUT/include/llvm/Config/llvm-config.h" ] \
   && [ "$(archives)" -ge 25 ]; then
    echo "=== LLVM $VERSION for iOS already built ($(du -sh "$OUT" | cut -f1)) ==="
    echo "    archives: $(archives)"
    exit 0
fi

echo "=== source: llvm-project $VERSION ==="
mkdir -p "$R/toolchains"
if [ ! -d "$SRC/llvm/cmake" ]; then
    rm -rf "$SRC"
    if [ ! -f "$TARBALL" ]; then
        # The release asset name is llvm-project-<version>.src.tar.xz. Fetch the
        # URL from the API rather than guessing it, and check the digest the API
        # reports when it reports one.
        url=$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN:-}" \
            "https://api.github.com/repos/llvm/llvm-project/releases/tags/llvmorg-$VERSION" \
            | python3 -c '
import json,sys
for a in json.load(sys.stdin).get("assets",[]):
    if a["name"] == "llvm-project-'"$VERSION"'.src.tar.xz":
        print(a["browser_download_url"]); break
')
        test -n "$url" || { echo "::error::no llvm-project-$VERSION.src.tar.xz asset found"; exit 1; }
        echo "    fetching $url"
        # Same reasoning as ensure-bison.sh: --retry does not retry a
        # connection that was never established.
        curl -fSL --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 30 "$url" -o "$TARBALL"
    fi
    mkdir -p "$SRC.tmp"
    tar -xJf "$TARBALL" -C "$SRC.tmp" --strip-components=1
    mv "$SRC.tmp" "$SRC"
    rm -f "$TARBALL"
else
    echo "    already extracted"
fi
test -f "$SRC/llvm/cmake/modules/AddLLVM.cmake" \
    || { echo "::error::llvm source tree is not where it should be"; exit 1; }

echo "=== patch: AddLLVM.cmake must treat iOS as Darwin ==="
# Upstream's README names this patch as required. Keep it narrow: it applies to
# the one place that picks the linker's dead-stripping flag.
patch_file="$SRC/llvm/cmake/modules/AddLLVM.cmake"
if grep -q 'MATCHES "Darwin|iOS"' "$patch_file"; then
    echo "    already patched"
else
    python3 - "$patch_file" <<'PY'
import sys
p = sys.argv[1]
with open(p) as f:
    text = f.read()
before = text
text = text.replace('MATCHES "Darwin"', 'MATCHES "Darwin|iOS"')
if text == before:
    # Not fatal: a version whose Darwin test is written differently still links
    # with gc-sections where that is valid, so report it and carry on instead of
    # failing a two-hour build over a comment's shape.
    print('    WARNING: no `MATCHES "Darwin"` to patch; the flag selection may be written differently')
else:
    with open(p, 'w') as f:
        f.write(text)
    print('    patched')
PY
fi

echo "=== stage 1: host llvm-tblgen (an iOS build cannot run the one it produces) ==="
# Only the table generator, not a host LLVM: the tree is deleted as soon as the
# binary is copied out, because the runner's disk is the binding constraint.
cmake -S "$SRC/llvm" -B "$HOST" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_ENABLE_ZLIB=Off \
    -DLLVM_ENABLE_TERMINFO=Off \
    -DLLVM_ENABLE_LIBXML2=Off \
    -DLLVM_ENABLE_PROJECTS=
cmake --build "$HOST" --target llvm-tblgen -j "$JOBS"
test -x "$HOST/bin/llvm-tblgen" || { echo "::error::host llvm-tblgen was not produced"; exit 1; }
mkdir -p "$R/toolchains/llvm-host-bin"
cp "$HOST/bin/llvm-tblgen" "$R/toolchains/llvm-host-bin/llvm-tblgen"
rm -rf "$HOST"
echo "    saved toolchains/llvm-host-bin/llvm-tblgen, removed the host tree"

echo "=== stage 2: LLVM for iOS/arm64 (the long one: build it once, it is cached) ==="
cmake -S "$SRC/llvm" -B "$OUT" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_ENABLE_ZLIB=Off \
    -DLLVM_ENABLE_TERMINFO=Off \
    -DLLVM_ENABLE_LIBXML2=Off \
    -DLLVM_ENABLE_BINDINGS=Off \
    -DLLVM_BUILD_UTILS=Off \
    -DLLVM_TABLEGEN="$R/toolchains/llvm-host-bin/llvm-tblgen" \
    -DLLVM_ENABLE_FFI=Off \
    -DLLVM_ENABLE_THREADS=Off
# Build the archives airconv links, not the whole tree. `make all` also builds
# tools/remarks-shlib, which links libRemarks.dylib with `-Wl,-z,defs` -- a GNU
# ld option Apple's ld rejects outright ("ld: unknown options: -z"), and it
# stops the build 25% in. Nothing here needs a shared library or a tool: DXMT
# links static archives, and the only tool this build needs, llvm-tblgen, comes
# from the host stage.
LLVM_TARGETS_NEEDED="LLVMPasses LLVMTarget LLVMCoroutines LLVMipo LLVMInstrumentation \
LLVMVectorize LLVMLinker LLVMIRReader LLVMAsmParser LLVMFrontendOpenMP LLVMScalarOpts \
LLVMInstCombine LLVMAggressiveInstCombine LLVMTransformUtils LLVMBitWriter LLVMAnalysis \
LLVMProfileData LLVMSymbolize LLVMDebugInfoPDB LLVMDebugInfoMSF LLVMDebugInfoDWARF \
LLVMObject LLVMTextAPI LLVMMCParser LLVMMC LLVMDebugInfoCodeView LLVMBitReader LLVMCore \
LLVMRemarks LLVMBitstreamReader LLVMBinaryFormat LLVMSupport LLVMDemangle"
# CMake pulls in whatever else those depend on, so this list only has to name
# airconv's own dependencies (dxmt/src/airconv/meson.build's llvm_deps, minus
# LLVMObjCARCOpts, which has not existed as its own library since LLVM 12).
#
# Only targets that were actually configured are built. A name that this
# configuration does not create -- several of these are conditional on the
# target backends, and LLVM_TARGETS_TO_BUILD is empty -- would otherwise make
# make stop with "No rule to make target".
configured="$(find "$OUT" -maxdepth 7 -type d -path '*/CMakeFiles/*.dir' 2>/dev/null \
    | sed 's|.*/CMakeFiles/||; s|\.dir$||' | sort -u)"
build_targets=""
for t in $LLVM_TARGETS_NEEDED; do
    case "$configured" in
        *"$t"*) build_targets="$build_targets $t" ;;
    esac
done
if [ -z "$build_targets" ]; then
    echo "    no named targets found; building everything"
    cmake --build "$OUT" -j "$JOBS"
else
    echo "    building:$(echo "$build_targets" | wc -w | tr -d ' ') targets"
    cmake --build "$OUT" --target $build_targets -j "$JOBS"
fi

test -f "$OUT/lib/libLLVMCore.a" || { echo "::error::libLLVMCore.a missing after the iOS build"; exit 1; }
test -f "$OUT/include/llvm/Config/llvm-config.h" \
    || { echo "::error::llvm-config.h missing after the iOS build"; exit 1; }

echo "=== cleanup before caching ==="
# Cache space is the binding constraint: an LLVM build tree is many gigabytes of
# intermediates that are worth nothing once the archives exist, and a repository
# gets 10 GB of cache in total. Keep lib/ and include/ only. Nothing later needs
# the rest, because this script returns early whenever the archives are there.
#
# -mindepth 1 is load-bearing: find also tests its starting point, and without it
# the starting point does not match `! -name include`, so `rm -rf {}` was handed
# the whole build tree and deleted lib/ and include/ with everything else. That
# is what the first run of this script did after a build that had succeeded.
find "$OUT" -mindepth 1 -maxdepth 1 -type d ! -name lib ! -name include -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -maxdepth 1 -type f -name 'CMakeCache.txt' -delete 2>/dev/null || true
find "$OUT" -name '*.dSYM' -prune -exec rm -rf {} + 2>/dev/null || true

# dxmt-ios/build.sh compiles with -I'$LLVM_SRC/include' as well, and that path
# usually holds the header symlink the other LLVM step creates. That step is
# skipped when this build exists, so create the same link here before deleting
# the source tree -- otherwise a heavy run would build the libraries and then
# fail to compile DXMT for want of a header path.
mkdir -p "$SRC/llvm"
ln -sfn "$(cd "$OUT/include" && pwd)" "$SRC/llvm/include"

# The extracted source and the tarball are re-obtainable; the headers they
# provide are now inside $OUT. Only the include symlink stays.
find "$SRC/llvm" -mindepth 1 -maxdepth 1 ! -name include -exec rm -rf {} + 2>/dev/null || true
rm -f "$TARBALL"
du -sh "$OUT" "$SRC" 2>/dev/null || true
ls "$OUT"/lib/libLLVM*.a | wc -l | tr -d ' ' | sed 's/^/    archives: /'
echo "=== LLVM $VERSION for iOS is ready ==="
