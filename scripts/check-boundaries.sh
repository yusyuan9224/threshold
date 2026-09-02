#!/bin/bash
# Architecture-boundary checks (docs/specs/architecture.md §2, security.md §3, ADR-004).
# Exit 1 on any violation. Run in CI and locally: scripts/check-boundaries.sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
say() { echo "BOUNDARY VIOLATION: $*"; fail=1; }

# 1. ThresholdDomain imports nothing but the Swift stdlib (no Foundation, no frameworks, no other targets).
if grep -rn -E '^\s*(@testable\s+)?import\s+' "$root/Sources/ThresholdDomain" | grep -v -E 'import\s+Swift\b'; then
  say "ThresholdDomain must not import any module"
fi

# 2. No private frameworks or undocumented Bluetooth databases anywhere in production sources.
for pat in 'MediaRemote' 'login\.framework' 'SACLockScreen' '/Library/Bluetooth' 'com\.apple\.Bluetooth\.plist' 'IOBluetooth' 'PrivateFrameworks'; do
  if grep -rn -E "$pat" "$root/Sources"; then say "private/undocumented dependency: $pat"; fi
done

# 3. Main line never stores or types the login password (ADR-001). Assisted Unlock is a reserved, non-v1 track.
for pat in 'SecItemAdd' 'SecItemCopyMatching' 'kSecClassGenericPassword' 'keyboardSetUnicodeString' 'CGEvent\(keyboardEventSource'; do
  if grep -rn -E "$pat" "$root/Sources"; then say "credential handling / keystroke synthesis in production sources: $pat"; fi
done

# 4. Undocumented screen-state signals may appear only inside ThresholdSystem (ADR-004).
for pat in 'com\.apple\.screenIsLocked' 'com\.apple\.screenIsUnlocked' 'CGSSessionScreenIsLocked' 'CGSessionCopyCurrentDictionary' 'shortcuts run'; do
  if grep -rln -E "$pat" "$root/Sources" | grep -v '/Sources/ThresholdSystem/'; then say "undocumented signal outside ThresholdSystem: $pat"; fi
done

# 5. Domain never reads a clock (ADR-003).
for pat in 'ContinuousClock' 'SuspendingClock' 'Date\(' 'DispatchTime\.now' 'clock_gettime' 'mach_absolute_time'; do
  if grep -rn -E "$pat" "$root/Sources/ThresholdDomain"; then say "Domain reads time: $pat"; fi
done

# 6. Fixtures must be anonymised: no UUID-shaped identifiers, no MAC addresses.
if [ -d "$root/Tests/Fixtures" ]; then
  if grep -rn -E '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$root/Tests/Fixtures"; then say "UUID in fixtures"; fi
  if grep -rn -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$root/Tests/Fixtures"; then say "MAC address in fixtures"; fi
fi

if [ "$fail" -eq 0 ]; then echo "boundaries OK"; fi
exit $fail
