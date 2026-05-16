#!/usr/bin/env bash
# Build the Go wasm-demo for the rootshell WASM runtime.
#
# Usage:
#   ./build.sh           # standard Go (default) — needs Go 1.21+
#   ./build.sh tinygo    # TinyGo — needs TinyGo 0.31+ (wasip1 target)
#
# Outputs go to different paths so you can keep both side-by-side:
#   dist/wasm-demo-go.wasm           # standard Go (~2 MB, full scheduler + GC)
#   dist/wasm-demo-go-tinygo.wasm    # TinyGo (~200–400 KB, trimmed runtime)
#
# Standard Go ships the full scheduler and GC. TinyGo trims most of that
# at the cost of some stdlib coverage gaps — both run this demo cleanly,
# but if you port something larger and hit `unimplemented`, fall back to
# standard Go.
#
# Get the resulting .wasm into the rootshell document directory on the
# device (Files app, or `scp` / `sftp` from a local shell tab) and run
# it from there. The WASM runtime is iOS / visionOS only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

COMPILER="${1:-go}"
mkdir -p "$SCRIPT_DIR/dist"

case "$COMPILER" in
    go)
        DEST="$SCRIPT_DIR/dist/wasm-demo-go.wasm"
        # -ldflags strip debug symbols / build IDs to bring the binary
        # closer in size to the Rust counterpart.
        GOOS=wasip1 GOARCH=wasm go build \
            -ldflags="-s -w" \
            -o "$DEST" .
        ;;
    tinygo)
        DEST="$SCRIPT_DIR/dist/wasm-demo-go-tinygo.wasm"
        if ! command -v tinygo >/dev/null 2>&1; then
            echo "error: tinygo not on PATH. Install via 'brew install tinygo' or" >&2
            echo "       https://tinygo.org/getting-started/install/macos/" >&2
            exit 1
        fi
        # -target=wasip1 requires TinyGo 0.31+. -no-debug strips DWARF;
        # -opt=z optimises for size.
        tinygo build \
            -target=wasip1 \
            -no-debug \
            -opt=z \
            -o "$DEST" .
        ;;
    *)
        echo "usage: $0 [go|tinygo]  (default: go)" >&2
        exit 2
        ;;
esac

echo "built $(wc -c < "$DEST") bytes -> $DEST"
