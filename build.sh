#!/bin/bash
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teammux build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "[1/4] Building Zig engine (libteammux)..."
cd engine
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a /tmp/libteammux-arm64.a
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a /tmp/libteammux-x86_64.a
cd ..
mkdir -p macos/Resources
lipo -create /tmp/libteammux-arm64.a /tmp/libteammux-x86_64.a -output macos/Resources/libteammux.a
echo "      → libteammux.a (universal) copied to macos/Resources/"

echo ""
echo "[2/4] Building Ghostty + Teammux app..."
zig build -Demit-macos-app=true

echo ""
echo "[3/4] Renaming app bundle..."
mv zig-out/Ghostty.app zig-out/Teammux.app

echo ""
echo "[4/4] Build complete."
echo "      → App: zig-out/Teammux.app"
echo "      → Launch: open zig-out/Teammux.app"
echo ""
