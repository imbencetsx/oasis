#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
app_dir="${OASIS_APP_DIR:-$PWD/build/[oasis].app}"
bundle_stage=$(mktemp -d /tmp/.oasis-cef-bundle.XXXXXX)
swift package --allow-writing-to-package-directory --allow-network-connections all \
  cef bundle --product Oasis --name '[oasis]' --bundle-id com.oasis.browser \
  --configuration "$configuration" --sign - --output "$bundle_stage"
mkdir -p "$(dirname "$app_dir")"
ditto "$bundle_stage/[oasis].app" "$app_dir"
mv "$app_dir/Contents/MacOS/[oasis]" "$app_dir/Contents/MacOS/Oasis"
python3 - "$bundle_stage" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
# Recreate generated resources so removed icons/fonts cannot survive old builds.
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
./scripts/compile-icon.sh
cp "$PWD/build/iconbuild/Assets.car" "$PWD/build/iconbuild/AppIcon.icns" "$app_dir/Contents/Resources/"
cp -R Resources/Fonts "$app_dir/Contents/Resources/"
cp Vendor/CefSwift/LICENSE "$app_dir/Contents/Resources/CefSwift-LICENSE.txt"
cp Vendor/CefSwift/Sources/CCef/LICENSE.CEF.txt "$app_dir/Contents/Resources/CEF-LICENSE.txt"
codesign --force --sign - "$app_dir"
printf '\nBuilt %s\n' "$app_dir"
