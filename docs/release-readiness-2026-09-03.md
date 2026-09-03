# v1.0 Readiness Report — 2026-09-03

Lead-agent report at main `f7b1b05`. Every claim below is reproducible from the repo; nothing is asserted about behaviour that was not measured.

## 1. Build / test commands and results (clean build, 2026-09-03)

| Command | Result |
|---|---|
| `swift package clean && scripts/check-boundaries.sh` | `boundaries OK`, exit 0 |
| `swift build` | `Build complete!`, zero warnings |
| `swift test` | `577 tests in 85 suites passed`, exit 0 |
| `scripts/make-app-bundle.sh release` | `build/Threshold.app (version 0.0.0, release)`, Info.plist lint OK |
| `swift build --package-path Tools/rssi-record` | `Build complete!` |
| `build/Threshold.app/Contents/MacOS/ThresholdApp` (8 s smoke) | process alive, no output, no files written |
| `swift build --package-path Tools/app-smoke && <bin>/app-smoke 15` (real adapters, headless, 15:25 CST) | Coordinator started with empty registry (no CBCentralManager until discovery); onboarding discovery idle→scanning→found in 560 ms, 22 identifiers / 8 named in 15 s; sensor initializing→healthy; providers: screen unlocked, session active, power awake, input idle 69.8 s; 4 Coordinator events recorded, 0 dropped; nothing written to the user's Application Support; exit 0 |
| `git status` | clean; single worktree on main |

Toolchain: macOS 26.6.2, Xcode 26.6, Swift 6.3.3; Package tools-version 6.0, deployment target macOS 14.0, no external dependencies. CI (`.github/workflows/ci.yml`, macos-15): every step it defines (boundaries, build, test, app bundle, Tools builds) was executed locally with exit 0. The repository has **no git remote** (`git remote` is empty), so no hosted CI run exists; creating a remote and pushing is a user action.

Test layers: L1 Domain unit (Signal/Presence/StateMachine/Policy/Calibration incl. property tests T-15 100k steps), L2 fixture replay (11 synthetic recordings with goldens), L3 Coordinator integration (T-03/07/08/09/12/18 + lifecycle/restart/stop), ThresholdAppKit end-to-end (FakeScanner → exactly one lock → ledger confirmed), L4 System adapter mapping/fail-closed tests, Bluetooth T-18/T-19 concurrency, Diagnostics privacy/fail-closed export.

## 2. Spike outcomes

| Spike | Result | Evidence (docs/spikes) |
|---|---|---|
| 009 Trusted device observability | **PARTIAL** | 600 s scan: iPhone/Watch/iPad advertised in 60/60 ten-second windows; identifier stable across scanner restart (11/11). Distance/lock/idle matrix, reboot, BT toggle, 1 h suitability, beacons **not run** |
| 004 CoreBluetooth lifecycle | **PARTIAL** (display-sleep criterion met) | Scan continues through display sleep (75 s + 136 s), no state events; system sleep/BT off-on/App Nap/24 h not run |
| 001 Screen lock state | **PARTIAL** | 4/4 events: notification trails query by 7–107 ms, no mismatch; `CGSSessionScreenIsLocked` absent == unlocked |
| 003 Wake behaviour | **PARTIAL** (toward GO) | Locked + display asleep: `IOPMAssertionDeclareUserActivity` 3/3 lit display ≤150 ms, no permission, lock unchanged; login window re-sleeps after ~33 s. System-sleep wake: not claimed (product semantics, system-integration.md §4) |
| 007 Lock method | **PARTIAL** | Path ① display sleep → locked in 41 ms / 76 ms (n=2, "require password immediately"); paths ③④ untested; ② excluded (needs Accessibility) |
| 008 Input idle | **CONDITIONAL GO** | `.hidSystemState` + `kCGAnyInputEventType`; resets on real input after unlock; not reset by lock-screen input; `.combinedSessionState` is reset by our own wake call → rejected. Provider returns nil unless session active and screen unlocked |
| 002 loginwindow | NOT RUN | MVP 6 only (Assisted Unlock, not in v1.0) |
| 005 / 006 Watch / Touch ID interaction | NOT RUN | need a human at the Mac |

Decisions propagated: bluetooth.md §1, system-integration.md §1/§4, ADR-009 (evidence status + wording rule), ADR-011 (amendment), proximity-domain.md §6.2/§7.3.

## 3. Supported-device matrix (evidence-based, updated 14:45 CST)

Third SPIKE-009 batch (1 h `Tools/rssi-record` capture through the production scanner + 1 h `ble-observe` identity capture, devices near the seated user, distance not controlled):

| Class | Verdict (SPIKE-009 criteria) | Evidence | Not yet measured |
|---|---|---|---|
| Apple Watch (same Apple ID) | **CONDITIONAL** | 1 h receiving 100% (361/361 windows), longest gap 6.9 s, RSSI median −58 / MAD 2; identifier unchanged across 19 h and scanner restart | 1 m / 3 m / 8 m split, reboot, BT off→on, forget/re-pair, device idle matrix |
| iPad (same Apple ID) | **CONDITIONAL** | 1 h receiving 100%, longest gap 9.9 s, RSSI median −56; identifier unchanged across 19 h | same; gap is at the 10 s limit |
| iPhone (same Apple ID) | **UNKNOWN — not listed** | 60/60 windows in the 600 s run on 2026-09-02; the next day its identifier did not reappear in 1 h and no identifier advertised an iPhone name | cross-day identity, 1 h suitability, whole matrix |
| Generic beacon | UNKNOWN — not listed | — | all |

The supported-device list is therefore: Apple Watch (conditional), iPad (conditional). User-facing copy says "verified near the desk", not "supported". Protocol to close the gaps: `Tools/rssi-record/README.md`.

## 4. Security / architecture conditions

Independent security review (main 2a1d763, read-only): PASS on all ten checks — no password handling, no private frameworks, undocumented screen signals confined to ThresholdSystem, fail-closed preconditions (unknown → indeterminate blocks lock and wake; nil idle blocks silence lock only), fixed-argv `pmset` with no shell, atomic JSON stores with typed decode errors, diagnostics aliasing + fail-closed export, fixtures free of identifiers, Bluetooth-only permission, no external packages, stale outcomes never re-dispatched. `scripts/check-boundaries.sh` enforces the same in CI.

Raw BLE → effect path: `BLEObservation → ObservationValidator → SignalPipeline → PresenceScorer → AnyDeviceFusion → ProximityEngine → ProximitySnapshot → PolicySnapshot → PolicyEngine → ActionLedger → Coordinator dispatch → LockControlling/WakeControlling`; no shortcut exists (reviewed).

## 5. Known limitations

- Wake on Return works only while the Mac is awake with the display asleep or locked; no wake from system sleep (by design, no supported mechanism).
- Lock strategy ① (IOKit `IORequestIdle`) has no direct spike sample; its `pmset` equivalent has n=2. Both are confirmed against `ScreenStateProviding`; unconfirmed locks retry ≤3× every 5 s then give up (surfaced in the menu).
- Scanner stream failure is a bounded fail-closed shutdown (`.unavailable(.scannerFailed)`), not recovery.
- Silence-based lock depends on SPIKE-008 conditions; screen saver / fast user switching / synthetic-event cases untested.
- GUI (MenuBarExtra, onboarding, calibration, settings windows): logic verified by 94 ThresholdAppKit tests, an 8 s bundle launch, and a 15 s headless run of the real composition root with production adapters (`Tools/app-smoke`); the visual layer itself has not been clicked through by a person.
- `SMAppService` login-item behaviour needs a signed, installed bundle to verify.
- Bundle identifier defaults to `dev.threshold.app`; set `THRESHOLD_BUNDLE_ID` before distribution.

## 6. Remaining external blockers (need the user)

1. SPIKE-009 distance/reboot/BT-toggle scenarios (all classes) and any iPhone evidence at all; SPIKE-007 repeated samples — require a person carrying the device / unlocking the Mac; tool and checklist are ready.
2. Hands-on GUI walkthrough of `build/Threshold.app` (onboarding → calibration → lock/wake on a real departure). Headless equivalents are automated (`Tools/app-smoke`); only the visual layer and a real departure remain.
3. Signing and notarization — Developer ID certificate, notarytool credentials, team ID. Everything that can be prepared without them is done: `scripts/sign-and-notarize.sh` (hardened runtime, notarize, staple, spctl; exits 2 without credentials) and `scripts/make-dmg.sh` (refuses unstapled bundles), both syntax-checked in CI (`docs/release.md` §4).
4. Create a git remote and push so the CI workflow runs on GitHub (the repo currently has no remote; the session has no push permission).
5. Product name trademark search before the first public release (README).

## 7. Defects

No known P0/P1 defects. All review findings (2 CRITICAL, 2 HIGH, several MEDIUM across branches) were fixed and re-verified before merge; remaining review notes are LOW/informational and recorded in the code comments or specs.
