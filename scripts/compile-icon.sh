#!/bin/bash
# Compile the Liquid Glass icon (Resources/AppIcon.icon) into a runtime
# Assets.car plus a flattened AppIcon.icns fallback, using Xcode's actool.
# The .icon folder is the source of truth (editable in Icon Composer);
# the bundle ships only the compiled outputs.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/iconbuild"
mkdir -p "$out"
xcrun actool Resources/AppIcon.icon --compile "$out" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$out/partial.plist" \
    --app-icon AppIcon --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx \
    | tail -n 5
printf 'Compiled icon -> %s/Assets.car\n' "$out"
