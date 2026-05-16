#!/usr/bin/env bash
# Build the Swift wasm-demo for the rootshell WASM runtime.
#
# One-time setup (Swift 6.3+ recommended for the swift.org wasm SDK; the
# `@_extern(wasm, module:, name:)` attribute it uses needs Swift 6.0+):
#
#   # 1. Install the official Swift WASM SDK from swift.org. Pick the
#   #    artifact bundle matching your local Swift toolchain. The 6.3.2
#   #    bundle below is current as of writing — replace with the version
#   #    listed at https://www.swift.org/install/macos/ if newer.
#   swift sdk install \
#     https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz \
#     --checksum a61f0584c93283589f8b2f42db05c1f9a182b506c2957271402992655591dd7c
#
#   # 2. Confirm it's installed. The bundle name (e.g. "swift-6.3.2-RELEASE_wasm")
#   #    is what gets passed to --swift-sdk below.
#   swift sdk list
#
#   # 3. Make sure your host Swift matches. The wasm SDK needs the same
#   #    major.minor as the toolchain driving the build. If your shipping
#   #    Apple Swift is older, install a matching swift.org toolchain via
#   #    swiftly: https://www.swift.org/install/macos/
#
# Output:
#   dist/wasm-demo-swift.wasm
#
# Get that file into the rootshell document directory on the device
# (Files app, or `scp` / `sftp` from a local shell tab) and run it
# from there. The WASM runtime is iOS / visionOS only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Bundle name as shown by `swift sdk list`. Override with SWIFT_SDK env var
# if you've installed a different version. The Swift 6.3.x swift.org wasm
# bundles target the `wasm32-unknown-wasip1` triple (note: wasip1, not the
# older wasi name).
SDK="${SWIFT_SDK:-swift-6.3.2-RELEASE_wasm}"

# -Osize asks the compiler to favour binary size over speed. Combined
# with stripping debug symbols and a final wasm-opt -Os pass, this brings
# the demo down from ~57 MB (if Foundation is imported) to a few MB.
swift build \
    --swift-sdk "$SDK" \
    -c release \
    -Xswiftc -Osize \
    -Xswiftc -gnone \
    -Xswiftc -wmo

# SwiftPM puts the binary under the target triple, not plain `release/`.
OUT="$(find "$SCRIPT_DIR/.build" -name wasm-demo-swift.wasm -path '*/release/*' -type f | head -n 1)"
if [ -z "$OUT" ]; then
    echo "error: built .wasm not found under .build/" >&2
    exit 1
fi

DEST="$SCRIPT_DIR/dist/wasm-demo-swift.wasm"
mkdir -p "$(dirname "$DEST")"
cp "$OUT" "$DEST"
PRE_SIZE=$(wc -c < "$DEST")

# Post-process with binaryen's wasm-opt for substantial size + startup wins.
# wasm-opt -Os runs ~20 size-shrinking passes and produces a much faster-to-
# parse binary, which matters a lot on low-end devices where module
# instantiation time dominates a small CLI's wall-clock runtime.
if command -v wasm-opt >/dev/null 2>&1; then
    TMP="${DEST}.opt"
    wasm-opt -Os --enable-bulk-memory --strip-debug --strip-producers \
        -o "$TMP" "$DEST"
    mv "$TMP" "$DEST"
    POST_SIZE=$(wc -c < "$DEST")
    echo "built ${PRE_SIZE} -> ${POST_SIZE} bytes (after wasm-opt -Os) -> $DEST"
else
    echo "note: wasm-opt not on PATH (brew install binaryen) -" \
         "skipping size pass. The binary will be larger and slower to" \
         "instantiate on device." >&2
    echo "built ${PRE_SIZE} bytes -> $DEST"
fi
