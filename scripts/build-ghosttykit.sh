#!/bin/sh
# Build GhosttyKit.xcframework from the pinned Ghostty submodule and copy it
# into vendor/, along with the resources the app bundle needs: Ghostty's themes
# and shell integration, and the xterm-ghostty terminfo.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ghostty="$root/vendor/ghostty"

git -C "$root" submodule update --init vendor/ghostty

cd "$ghostty"
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native

rm -rf "$root/vendor/GhosttyKit.xcframework" "$root/vendor/resources"
cp -R "$ghostty/macos/GhosttyKit.xcframework" "$root/vendor/GhosttyKit.xcframework"
mkdir -p "$root/vendor/resources"
cp -R "$ghostty/zig-out/share/ghostty" "$root/vendor/resources/ghostty"
cp -R "$ghostty/zig-out/share/terminfo" "$root/vendor/resources/terminfo"
echo "Built vendor/GhosttyKit.xcframework"
