# v1.0 Readiness Report — 2026-09-03

Lead-agent report at main `ed562ff`. Every claim below is reproducible from the repo; nothing is asserted about behaviour that was not measured.

## 1. Build / test commands and results (clean build, 2026-09-03 22:30 CST)

| Command | Result |
|---|---|
| `swift package clean && scripts/check-boundaries.sh` | `boundaries OK`, exit 0 |
| `swift build` | `Build complete!`, zero warnings |
| `swift test` | `577 tests in 85 suites passed`, exit 0 |
| `scripts/make-app-bundle.sh release` | `build/Threshold.app (version 0.0.0, release)`, Info.plist lint OK |
| `swift build --package-path Tools/rssi-record` | `Build complete!` |
| `swift build --package-path Tools/app-smoke && <bin>/app-smoke 15` (real adapters, headless) | Coordinator started with empty registry; onboarding discovery idle→scanning→found in 560 ms; 4 Coordinator events recorded, 0 dropped; nothing written to the user's Application Support; exit 0 |
| `git status` | clean; single worktree on main |

Toolchain: macOS 26.6.2, Xcode 26.6, Swift 6.3.3; Package tools-version 6.0, deployment target macOS 14.0, no external dependencies. CI (`.github/workflows/ci.yml`, macos-15): every step it defines (shell-script lint, boundaries, build, test, app bundle, Tools builds) was executed locally with exit 0. The repository has **no git remote** as of this report; pushing one so the workflow runs on GitHub is in progress (§7).

Test layers: L1 Domain unit (Signal/Presence/StateMachine/Policy/Calibration incl. property tests T-15 100k steps), L2 fixture replay (11 synthetic recordings with goldens), L3 Coordinator integration (T-03/07/08/09/12/18 + lifecycle/restart/stop), ThresholdAppKit end-to-end (FakeScanner → exactly one lock → ledger confirmed), L4 System adapter mapping/fail-closed tests, Bluetooth T-18/T-19 concurrency, Diagnostics privacy/fail-closed export.

## 2. Real-device end-to-end verification (2026-09-03 evening, operator present)

This is the first session with a person and a real trusted device at the Mac. It found and fixed two defects that no synthetic test, headless smoke run, or shell-driven spike sample could reach, because both require the app's own composition-root wiring driving a real departure and return.

**Auto Lock failed 3 times and gave up on the first real departure.** `MacOSLockController.defaultStrategies` tried IOKit `IORequestIdle` first. An isolated test proved `IORegistryEntrySetCFProperty(IORequestIdle)` returns `KERN_SUCCESS` on this Mac (`Mac17,2`, macOS 26.6.2) without the display actually sleeping (9 s observed, 0 sleep events) — the strategy "succeeds" and `requestLock()` stops there, never reaching the `pmset` fallback SPIKE-007 already had 16/16 real samples for. **Fixed**: default order swapped so the proven `pmset` path is primary (commit `ed562ff`).

**Wake never fired even after presence correctly returned to `.present`.** `Coordinator`'s cached `power` field is set from `NSWorkspace.screensDidSleep`/`screensDidWakeNotification`, which fired **0 times** across 14 real display-sleep cycles that evening — so `power` stayed `.awake` through a real lock and the wake precondition (`power == .displayAsleep`) could never pass. **Fixed**: `Coordinator.evaluate(trigger:)` now refreshes `power` from `powerProvider.current` (a live `CGDisplayIsAsleep` query) before building each `PolicySnapshot` — the same "read at decision time" principle already used for `inputIdle` (commit `ed562ff`).

**Verified after both fixes**, end to end, with a real iPhone, real `CoreBluetoothScanner`, real `Coordinator`/`PolicyEngine`/`MacOSLockController`/`MacOSWakeController`, via the app's own Export Diagnostics (de-identified JSON, reviewed for identifiers before use): presence `unknown → away` (21 s, `measuredFar`) → lock dispatched → `outcome applied` → 13 s later presence `away → present` → wake dispatched and applied **in the same second**. The operator's perceived "delay" on return is the `confirmDuration` (3 s) presence debounce, not wake latency — wake itself fires the same second presence confirms, consistent with SPIKE-003's ≤150 ms measurement.

The GUI itself was walked through for the first time: first-launch onboarding → device picker (selected the real iPhone) → near/far calibration produced a real `CalibrationProfile` (`nearBaseline −45.5, farBaseline −64, midpoint −54.75, slope 4.625, noise 4.5`, consistent in direction with the independently-measured RSSI-vs-distance data below) → main menu showing live status, correct trusted-device name, and a fail-closed `.power` precondition banner that correctly held off action until its condition was met. One UX-adjacent finding, not a code defect: the app's newly-created menu-bar status item was initially hidden by a third-party menu-bar manager (Ice) that crashed three times during the session; unrelated to Threshold, resolved by relaunching after Ice's crash cycle passed.

## 3. Spike outcomes

| Spike | Result | Evidence (docs/spikes) |
|---|---|---|
| 009 Trusted device observability | **PARTIAL** — iPhone CONDITIONAL GO, Watch conditional (near only), iPad conditional | Controlled 1 m / 3 m / 8 m distance run (600 s each, iPhone locked+screen off, Watch worn): iPhone 100% receiving at all three distances, RSSI monotonic (−50 / −60 / −68); Watch 98.4%/100% near, **83.6% and a 25.7 s gap at 8 m** (fails the ≤10 s criterion). iPhone identifier confirmed unchanged across Bluetooth off→on (both ends) and a full iPhone power cycle. iPad has only an earlier 1 h uncontrolled-distance run. Beacons and the full reboot/forget-re-pair matrix for Watch/iPad not run |
| 004 CoreBluetooth lifecycle | **PARTIAL** — display-sleep and BT off→on both GO | Scan continues through display sleep (75 s + 136 s) and a real Mac-side Bluetooth off→on (35.6 s outage, correctly reported as sensor `unavailable.poweredOff`, not device silence — first real-hardware evidence for "sensor failure ≠ absence"); resumes without re-issuing `scanForPeripherals`; identifier unchanged. System sleep/App Nap/24 h not run |
| 001 Screen lock state | **PARTIAL** | 4/4 events: notification trails query by 7–107 ms, no mismatch; `CGSSessionScreenIsLocked` absent == unlocked |
| 003 Wake behaviour | **PARTIAL** (toward GO) | Locked + display asleep: `IOPMAssertionDeclareUserActivity` 3/3 lit display ≤150 ms in isolation; confirmed again as part of the real end-to-end wake dispatch above. No wake-from-system-sleep claim (product semantics, system-integration.md §4) |
| 007 Lock method | **PARTIAL, split by strategy** | `pmset displaysleepnow`: **GO**, 16/16 real samples, 41–337 ms, including one real end-to-end departure. IOKit `IORequestIdle`: **NO-GO on this hardware** — see §2; kept as a secondary fallback since a different Mac/OS may honor it. Paths ③④ untested; ② excluded (needs Accessibility) |
| 005 Apple Watch unlock | **CONDITIONAL GO** | 9/9 successful native Watch unlocks, 0 failures, including 2 with Threshold's own BLE scan actively running (no interference observed). App's own wake path not yet the trigger tested (all trials used `pmset displaysleepnow`) |
| 006 Touch ID interaction | **GO** (built-in keyboard, n=5) | 5/5 one-tap unlocks, 370–624 ms, no extra keypress needed. External Touch ID keyboard untested |
| 008 Input idle | **CONDITIONAL GO** | `.hidSystemState` + `kCGAnyInputEventType`; resets on real input after unlock; not reset by lock-screen input; `.combinedSessionState` is reset by our own wake call → rejected |
| 002 loginwindow | NOT RUN | MVP 6 only (Assisted Unlock, not in v1.0) |

Decisions propagated: bluetooth.md §1/§4, system-integration.md §1/§2/§4, ADR-009 (evidence status + supported list), ADR-011, `SupportedDevices.swift` onboarding copy, README supported-device table and spike table.

## 4. Supported-device matrix (evidence-based, updated 2026-09-03 evening)

Controlled distance run (§2/§3 above) plus the third SPIKE-009 batch (1 h uncontrolled-distance):

| Class | Verdict | Evidence | Not yet measured |
|---|---|---|---|
| **iPhone** (same Apple ID) | **CONDITIONAL GO** | 100% receiving at 1 m / 3 m / 8 m (through a closed door), longest gap 9.0–10.2 s, RSSI monotonic and separable; identifier unchanged across ~22.5 h, both-end Bluetooth off→on, and a full power cycle | reboot/BT-toggle matrix for cross-checking edge cases; forget/re-pair; 20-minute-per-segment version of the distance run |
| Apple Watch (same Apple ID) | **CONDITIONAL — near distance only** | 1 m 98.4%, 3 m 100%, longest gap ≤9.9 s | **8 m: 83.6% receiving, 25.7 s longest gap — fails the criterion.** RSSI non-monotonic (1 m median −59, 3 m median −41), unsuitable for distance calibration. Not a reliable sole signal for "has left" |
| iPad (same Apple ID) | **CONDITIONAL** | 1 h uncontrolled-distance: 100% receiving, longest gap 9.9 s; identifier unchanged across ~22.5 h | distance split, reboot, BT toggle, forget/re-pair |
| Generic beacon | UNKNOWN — not listed | — | all |

Supported-device list: **iPhone (conditional go, primary)**, Apple Watch (conditional, near-distance witness only), iPad (conditional). Onboarding copy (`SupportedDevices.swift`) and README both state this explicitly, including that Watch should be paired with a phone rather than relied on alone for departure detection.

## 5. Security / architecture conditions

Independent security review (main, read-only, prior to tonight's changes): PASS on all ten checks — no password handling, no private frameworks, undocumented screen signals confined to ThresholdSystem, fail-closed preconditions (unknown → indeterminate blocks lock and wake; nil idle blocks silence lock only), fixed-argv `pmset` with no shell, atomic JSON stores with typed decode errors, diagnostics aliasing + fail-closed export, fixtures free of identifiers, Bluetooth-only permission, no external packages, stale outcomes never re-dispatched. `scripts/check-boundaries.sh` enforces the same in CI and was re-run clean after tonight's two fixes.

Raw BLE → effect path unchanged by tonight's fixes: `BLEObservation → ObservationValidator → SignalPipeline → PresenceScorer → AnyDeviceFusion → ProximityEngine → ProximitySnapshot → PolicySnapshot → PolicyEngine → ActionLedger → Coordinator dispatch → LockControlling/WakeControlling`; no shortcut exists. Both fixes only changed *which* system-facing strategy is tried first and *how fresh* one precondition field is — neither touches this path or the fail-closed guarantee. Tonight's real Mac-side Bluetooth outage (§3, SPIKE-004) is now first-hand evidence, not just a unit test, that a sensor failure surfaces as `unavailable.poweredOff` and never as false absence.

## 6. Known limitations

- Wake on Return works only while the Mac is awake with the display asleep or locked; no wake from system sleep (by design, no supported mechanism).
- Apple Watch loses reliable observability past ~8 m (measured 83.6% receiving, 25.7 s longest gap) — it is listed as a supported device but only as a near-distance witness, not for departure detection on its own.
- IOKit `IORequestIdle` lock strategy is confirmed non-functional on this Mac/OS; kept only as a secondary fallback pending evidence from other hardware.
- `EngineConfiguration.silentThreshold` (10 s default) is crossed by real iPhone advertising gaps measured at the desk (10.2 s once in 774 samples); cannot cause a false lock (`silenceLock` requires 180 s continuous silence) but can cause avoidable `.silent` flapping. Not changed tonight — flagged for a dedicated ADR with a 20-minute-segment re-measurement.
- Scanner stream failure is a bounded fail-closed shutdown (`.unavailable(.scannerFailed)`), not recovery.
- Silence-based lock depends on SPIKE-008 conditions; screen saver / fast user switching / synthetic-event cases untested.
- `SMAppService` login-item behaviour needs a signed, installed bundle to verify.
- Bundle identifier defaults to `dev.threshold.app`; set `THRESHOLD_BUNDLE_ID` before distribution.

## 7. Remaining external blockers (need the user)

1. Signing and notarization — Developer ID certificate, notarytool credentials, team ID. Everything that can be prepared without them is done: `scripts/sign-and-notarize.sh` (hardened runtime, notarize, staple, spctl; exits 2 without credentials) and `scripts/make-dmg.sh` (refuses unstapled bundles), both syntax-checked in CI (`docs/release.md` §4).
2. Push to a git remote so the CI workflow runs on GitHub — repo creation and the push itself are in progress as of this report; not yet confirmed green.
3. Product name trademark search before the first public release (README).
4. Apple Watch / iPad reboot and forget-re-pair identity scenarios; iPad and beacon distance matrices; SPIKE-007 samples for lock paths ③④; 20-minute-per-segment version of the SPIKE-009 distance run — all optional hardening beyond what already gates the supported-device list.

## 8. Defects

**Two P0 defects were found and fixed this session** by real-device testing (§2): Auto Lock failing outright (wrong default strategy order masking a non-functional IOKit path) and Wake never firing (a state cache that only a non-firing system notification could ever update). Both are fixed, re-verified end to end with real hardware, and covered by the existing 577-test suite plus the specific real-device evidence in §2 — no unit test previously covered either failure mode because both require the live composition root, not a fake.

No other known P0/P1 defects. All earlier review findings (2 CRITICAL, 2 HIGH, several MEDIUM across branches) were fixed and re-verified before merge; remaining review notes are LOW/informational and recorded in the code comments or specs.
