#!/bin/bash
set -euo pipefail

command -v zig >/dev/null 2>&1 || { echo "ERROR: 'zig' not found. Install from https://ziglang.org/download/"; exit 1; }
command -v lipo >/dev/null 2>&1 || { echo "ERROR: 'lipo' not found. Run: xcode-select --install"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teammux build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo ""
echo "[1/3] Building Zig engine (libteammux)..."
cd engine
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a "$STAGING/libteammux-arm64.a"
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a "$STAGING/libteammux-x86_64.a"
cd ..
mkdir -p macos/Resources
lipo -create "$STAGING/libteammux-arm64.a" "$STAGING/libteammux-x86_64.a" -output macos/Resources/libteammux.a
echo "      → libteammux.a (universal) copied to macos/Resources/"

echo ""
echo "[2/3] Building Ghostty + Teammux app..."
zig build -Demit-macos-app=true
rm -rf zig-out/Teammux.app
mv zig-out/Ghostty.app zig-out/Teammux.app

echo ""
echo "[3/3] Build complete."
echo "      → App: zig-out/Teammux.app"
echo "      → Launch: open zig-out/Teammux.app"
echo ""
