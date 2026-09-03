#!/bin/bash
# Sign, notarize and staple Threshold.app (docs/release.md §4).
#
# Requires credentials this repository does not and must not contain. Without them the script
# explains what is missing and exits 2 — it never signs ad hoc and never touches the keychain.
#
# Usage: scripts/sign-and-notarize.sh [path/to/Threshold.app]
# Env:   THRESHOLD_SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"
#        THRESHOLD_NOTARY_PROFILE  name of a `xcrun notarytool store-credentials` keychain profile
#        THRESHOLD_SKIP_NOTARIZE=1 sign only (local testing of the signing step)
set -euo pipefail
app="${1:-build/Threshold.app}"
identity="${THRESHOLD_SIGN_IDENTITY:-}"
profile="${THRESHOLD_NOTARY_PROFILE:-}"

missing=()
[ -n "$identity" ] || missing+=("THRESHOLD_SIGN_IDENTITY (Developer ID Application certificate in the login keychain)")
if [ "${THRESHOLD_SKIP_NOTARIZE:-0}" != "1" ]; then
  [ -n "$profile" ] || missing+=("THRESHOLD_NOTARY_PROFILE (xcrun notarytool store-credentials --apple-id … --team-id … --password <app-specific>)")
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "EXTERNAL BLOCKER: signing/notarization credentials are not available in this environment." >&2
  printf '  missing: %s\n' "${missing[@]}" >&2
  echo "See docs/release.md §4. Nothing was signed." >&2
  exit 2
fi
[ -d "$app" ] || { echo "bundle not found: $app (run scripts/make-app-bundle.sh release first)" >&2; exit 1; }

# Hardened runtime, no entitlements: the app is not sandboxed (IOKit display wrangler and
# CGSession queries need the un-sandboxed process) and needs no sandbox entitlements for
# Bluetooth — TCC gates it via NSBluetoothAlwaysUsageDescription (docs/release.md §4).
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

if [ "${THRESHOLD_SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "signed (notarization skipped): $app"
  exit 0
fi

zip="${app%.app}.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
echo "signed, notarized and stapled: $app"
