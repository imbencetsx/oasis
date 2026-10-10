#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

stage="$PWD/build/dmg-stage"
mount_dir="$PWD/build/dmg-mount"
image="$PWD/build/oasis-installer-rw.dmg"
output="$PWD/dist/[oasis].dmg"
python="$PWD/build/dmg-tools/bin/python"
if [ ! -x "$python" ]; then
    python3 -m venv build/dmg-tools
fi
"$python" -m pip install --quiet -r scripts/dmg-requirements.txt
# Only clear the disposable directory owned by this packaging script.
"$python" - <<'PY'
from pathlib import Path
import shutil
stage = Path('build/dmg-stage')
if stage.exists():
    shutil.rmtree(stage)
(stage / '.background').mkdir(parents=True)
PY
mkdir -p dist "$mount_dir"
ditto 'build/[oasis].app' "$stage/[oasis].app"
ln -s /Applications "$stage/Applications"
swift scripts/make-dmg-background.swift Resources/Fonts/GeistMono-Regular.ttf "$stage/.background/installer.png"
rm -f "$image"
hdiutil create -quiet -srcfolder "$stage" -volname '[oasis]' -fs HFS+ -format UDRW "$image"
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then hdiutil detach -quiet "$mount_dir" || true; fi
}
trap cleanup EXIT
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mount_dir" "$image"
mounted=true
"$python" scripts/configure-dmg.py "$mount_dir"
hdiutil detach -quiet "$mount_dir"
mounted=false
hdiutil convert -quiet "$image" -format UDZO -imagekey zlib-level=9 -o "$output" -ov
rm -f "$image"
printf '\nBuilt %s\n' "$output"
