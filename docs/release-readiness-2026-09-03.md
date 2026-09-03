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
| `git status` | clean; single worktree on main |

Toolchain: macOS 26.6.2, Xcode 26.6, Swift 6.3.3; Package tools-version 6.0, deployment target macOS 14.0, no external dependencies. CI (`.github/workflows/ci.yml`, macos-15) runs the same steps; it has **not** been executed remotely in this session (nothing was pushed).

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

## 3. Supported-device matrix

There is **no supported-device list yet** (ADR-009 amendment). Observation records only:

| Class | Observed | Not yet measured |
|---|---|---|
| iPhone (same Apple ID) | continuous advertisements, median 8/10 s, RSSI median −46 dBm at desk | pocket / 3 m / next room, locked+idle 5/30/60 min, reboot, BT toggle, other Apple ID |
| Apple Watch | continuous, median 8/10 s | same |
| iPad | continuous, median 8/10 s | same |
| Other Mac | intermittent (18–20 of 60 windows) | — |
| AirPods | intermittent | connected-to-iPhone / in case |
| Generic beacon | not tested | all |

User-run protocol: `Tools/rssi-record/README.md` (scenario names, `--profile`, privacy rule). Captures without a calibration profile must not receive goldens.

## 4. Security / architecture conditions

Independent security review (main 2a1d763, read-only): PASS on all ten checks — no password handling, no private frameworks, undocumented screen signals confined to ThresholdSystem, fail-closed preconditions (unknown → indeterminate blocks lock and wake; nil idle blocks silence lock only), fixed-argv `pmset` with no shell, atomic JSON stores with typed decode errors, diagnostics aliasing + fail-closed export, fixtures free of identifiers, Bluetooth-only permission, no external packages, stale outcomes never re-dispatched. `scripts/check-boundaries.sh` enforces the same in CI.

Raw BLE → effect path: `BLEObservation → ObservationValidator → SignalPipeline → PresenceScorer → AnyDeviceFusion → ProximityEngine → ProximitySnapshot → PolicySnapshot → PolicyEngine → ActionLedger → Coordinator dispatch → LockControlling/WakeControlling`; no shortcut exists (reviewed).

## 5. Known limitations

- Wake on Return works only while the Mac is awake with the display asleep or locked; no wake from system sleep (by design, no supported mechanism).
- Lock strategy ① (IOKit `IORequestIdle`) has no direct spike sample; its `pmset` equivalent has n=2. Both are confirmed against `ScreenStateProviding`; unconfirmed locks retry ≤3× every 5 s then give up (surfaced in the menu).
- Scanner stream failure is a bounded fail-closed shutdown (`.unavailable(.scannerFailed)`), not recovery.
- Silence-based lock depends on SPIKE-008 conditions; screen saver / fast user switching / synthetic-event cases untested.
- GUI (MenuBarExtra, onboarding, calibration, settings windows) verified by unit tests and an 8 s launch smoke only; no human has clicked through it.
- `SMAppService` login-item behaviour needs a signed, installed bundle to verify.
- Bundle identifier defaults to `dev.threshold.app`; set `THRESHOLD_BUNDLE_ID` before distribution.

## 6. Remaining external blockers (need the user)

1. SPIKE-009 device matrix and SPIKE-007 repeated samples — require a person carrying the phone / unlocking the Mac; tool and checklist are ready.
2. Hands-on GUI walkthrough of `build/Threshold.app` (onboarding → calibration → lock/wake on a real departure).
3. Signing and notarization — Developer ID certificate, notarytool credentials, team ID (`docs/release.md` §4).
4. Push to run CI on GitHub (the session has no push permission).
5. Product name trademark search before the first public release (README).

## 7. Defects

No known P0/P1 defects. All review findings (2 CRITICAL, 2 HIGH, several MEDIUM across branches) were fixed and re-verified before merge; remaining review notes are LOW/informational and recorded in the code comments or specs.
