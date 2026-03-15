#!/bin/bash
set -euo pipefail

command -v zig >/dev/null 2>&1 || { echo "ERROR: 'zig' not found. Install from https://ziglang.org/download/"; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teammux build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "[1/3] Building Zig engine (libteammux)..."
cd engine
zig build -Doptimize=ReleaseFast
cd ..
mkdir -p macos/Resources
cp engine/zig-out/lib/libteammux.a macos/Resources/libteammux.a
echo "      → libteammux.a copied to macos/Resources/"

echo ""
echo "[2/3] Building Ghostty + Teammux app..."
zig build -Demit-macos-app=true

echo ""
echo "[3/3] Renaming app bundle..."
rm -rf zig-out/Teammux.app
mv zig-out/Ghostty.app zig-out/Teammux.app

echo ""
echo "Build complete."
echo "      → App: zig-out/Teammux.app"
echo "      → Launch: open zig-out/Teammux.app"
echo ""
