#!/bin/bash
# Pick an Xcode that can actually build this app, and make sure the Metal
# compiler is installed.
#
# Two requirements, both learned from a run rather than assumed:
#
#  1. The iOS 26 SDK. The runner image's default Xcode is 16.x with the iOS 18
#     SDK, and dxmt/src/winemetal/unix/winemetal_unix.c imports
#     <MetalFX/MetalFX.h> and uses MTLFXFrameInterpolatorDescriptor for the
#     optional frame-generation path. That class arrives in the iOS 26 SDK, so
#     with 16.x the compile fails with "use of undeclared identifier
#     'MTLFXFrameInterpolatorDescriptor'". The app's own deployment target is
#     26.0 for the same reason.
#
#  2. The Metal toolchain. Xcode 26 no longer ships `metal`/`metallib` in the
#     box; they come from a component that has to be downloaded, and
#     dxmt-ios/build.sh compiles DXMT's .metal shaders with
#     `xcrun -sdk macosx metal`. Without it the shader headers cannot be
#     generated.
#
# Idempotent, and it prints what it chose so a log always says which Xcode a
# build used.
set -euo pipefail

WANT_SDK="${WANT_SDK:-26}"

echo "=== Xcodes on this runner ==="
ls -d /Applications/Xcode*.app 2>/dev/null || echo "    (none)"

# Newest by version. `sort -V` orders 16.4 before 26.0, which a plain sort does
# not, and that inversion would pick the wrong one every time.
newest=$(ls -d /Applications/Xcode*.app 2>/dev/null | sed 's|.*/Xcode||; s|\.app$||' \
    | sort -V | tail -1 || true)

if [ -n "$newest" ]; then
    current=$(xcode-select -p 2>/dev/null || true)
    echo "=== selecting Xcode $newest (current: $current) ==="
    sudo xcode-select -s "/Applications/Xcode$newest.app"
fi

echo "=== xcodebuild ==="
xcodebuild -version
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
echo "iphoneos SDK: $ios_sdk"
xcrun --sdk macosx --show-sdk-version | sed 's/^/macosx SDK: /'

# Fail here, with the number, rather than one file deep in a 40-minute run.
if [ "${ios_sdk%%.*}" -lt "$WANT_SDK" ]; then
    echo "::error::iphoneos SDK $ios_sdk is older than $WANT_SDK, which MetalFX frame interpolation and the app's deployment target both need"
    exit 1
fi

echo "=== Metal toolchain ==="
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    xcrun -sdk macosx metal --version | head -2 | sed 's/^/    /'
else
    # Xcode 26 moved it out of the box. This is a real download and takes a few
    # minutes; it is skipped whenever the image already has it.
    echo "    not installed; downloading the Metal toolchain component"
    # It installs inside the Xcode bundle, which the runner user may not own,
    # so retry the same command with sudo rather than guessing which case this
    # image is.
    xcodebuild -downloadComponent MetalToolchain \
        || sudo xcodebuild -downloadComponent MetalToolchain \
        || { echo "::error::the Metal toolchain is required to compile DXMT's shaders and could not be installed"; exit 1; }
    xcrun -sdk macosx metal --version | head -2 | sed 's/^/    /'
fi

echo "=== xcode selection done ==="
