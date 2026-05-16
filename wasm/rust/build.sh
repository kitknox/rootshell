#!/usr/bin/env bash
# Build the Rust wasm-demo for the rootshell WASM runtime.
#
# One-time setup:
#   rustup target add wasm32-wasip1
#
# Output:
#   dist/wasm-demo.wasm
#
# Get that file into the rootshell document directory on the device
# (Files app, or `scp` / `sftp` from a local shell tab) and run it
# from there. The WASM runtime is iOS / visionOS only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

cargo build --target wasm32-wasip1 --release

OUT="target/wasm32-wasip1/release/wasm-demo.wasm"
DEST="$SCRIPT_DIR/dist/wasm-demo.wasm"

mkdir -p "$(dirname "$DEST")"
cp "$OUT" "$DEST"

echo "built $(wc -c < "$DEST") bytes -> $DEST"
