#!/bin/sh
# Build Hauntty and wrap it in build/Hauntty.app. Pass "debug" for a debug build.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-release}

if [ ! -d "$root/vendor/GhosttyKit.xcframework" ]; then
  echo "Missing vendor/GhosttyKit.xcframework. Run scripts/build-ghosttykit.sh first." >&2
  exit 1
fi

cd "$root"
swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)

app="$root/build/Hauntty.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Hauntty" "$app/Contents/MacOS/Hauntty"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# libghostty finds its themes by looking for terminfo next to the executable.
cp -R "$root/vendor/resources/ghostty" "$app/Contents/Resources/ghostty"
cp -R "$root/vendor/resources/terminfo" "$app/Contents/Resources/terminfo"
codesign --force --sign - "$app"
echo "Built $app"
