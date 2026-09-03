#!/bin/bash
# Package a signed+stapled Threshold.app into a distributable DMG (docs/release.md §4).
# Maintainer-run; requires the bundle to be notarized first. Usage: scripts/make-dmg.sh [app] [out.dmg]
set -euo pipefail
app="${1:-build/Threshold.app}"
out="${2:-build/Threshold.dmg}"
[ -d "$app" ] || { echo "bundle not found: $app" >&2; exit 1; }
xcrun stapler validate "$app" >/dev/null 2>&1 || { echo "refusing to package an unstapled bundle: run scripts/sign-and-notarize.sh first" >&2; exit 2; }
stage="$(mktemp -d)"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$out"
hdiutil create -volname "Threshold" -srcfolder "$stage" -ov -format UDZO "$out"
rm -r "$stage"
echo "dmg: $out"
