#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
swift build -c "$configuration"
bin_dir=$(swift build -c "$configuration" --show-bin-path)
app_dir="$PWD/build/[oasis].app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/Oasis" "$app_dir/Contents/MacOS/Oasis"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
rm -f "$app_dir/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$app_dir/Contents/Resources/"
codesign --force --sign - "$app_dir"
printf '\nBuilt %s\n' "$app_dir"
