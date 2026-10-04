#!/bin/bash
# Build libmadeira_rppairing.a (on-device remote pairing for Built-in StikJIT,
# app/Madeira/JITPairing.swift) for iOS arm64 and copy it to app/Madeira/,
# where the app target links it. The C interface is app/Madeira/MadeiraRPPairing.h.
#
# Dependencies come from crates.io at the versions in Cargo.lock (idevice is
# MIT, jkcoxson/idevice; see THIRD-PARTY-NOTICES.md). Their licence notices
# are regenerated into app/Madeira/legal/LICENSES-rppairing-crates.txt, which
# the app bundles. Needs rustup with the aarch64-apple-ios target
# (`rustup target add aarch64-apple-ios`) and python3.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
TARGET=aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=17.0

# A fresh runner ships the stable toolchain for the HOST only, so `cargo build
# --target aarch64-apple-ios` dies with "can't find crate for `core`" and the
# unhelpful "the aarch64-apple-ios target may not be installed". Install it here
# rather than in build.yml, so a hand run, the stage workflow and a full build.yml
# all behave the same way -- and so this script is not silently dependent on
# whatever the image happens to carry. `rustup target add` is idempotent.
rustup target add "$TARGET"

cd "$BUILD_DIR"
cargo build --release --locked --target "$TARGET"
cp "target/$TARGET/release/libmadeira_rppairing.a" "$REPO_ROOT/app/Madeira/libmadeira_rppairing.a"
echo "-> app/Madeira/libmadeira_rppairing.a"
python3 "$BUILD_DIR/notices.py" "$REPO_ROOT/app/Madeira/legal/LICENSES-rppairing-crates.txt"
