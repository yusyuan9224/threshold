#!/bin/bash
# Assemble Threshold.app from the SwiftPM executable (ADR-011).
# Usage: scripts/make-app-bundle.sh [debug|release] [output-dir]
# Signing/notarization are separate steps (docs/release.md) and need credentials this script never touches.
set -euo pipefail
config="${1:-release}"
out="${2:-build}"
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$root/CHANGELOG.md" | head -1)"
version="${version:-0.0.0}"
bundle_id="${THRESHOLD_BUNDLE_ID:-dev.threshold.app}"

swift build -c "$config" --product ThresholdApp --package-path "$root"
bin="$(swift build -c "$config" --package-path "$root" --show-bin-path)/ThresholdApp"
[ -x "$bin" ] || { echo "executable not found: $bin" >&2; exit 1; }

case "$out" in
  /*) out_dir="$out" ;;
  *) out_dir="$root/$out" ;;
esac
app="$out_dir/Threshold.app"
# Only the bundle this script produced is replaced; never anything outside "$out".
if [ -d "$app" ]; then rm -r "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ThresholdApp"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>ThresholdApp</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Threshold</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Threshold observes the Bluetooth signal of your own trusted device to lock this Mac when you leave and wake the display when you return. It never connects to the device.</string>
  <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$app/Contents/PkgInfo"
plutil -lint "$app/Contents/Info.plist" >/dev/null
echo "bundled: $app (version $version, $config)"
