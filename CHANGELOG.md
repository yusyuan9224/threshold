# Changelog

All notable changes are recorded here. Format: Keep a Changelog; versions follow SemVer.

## [Unreleased]

### Fixed
- `rssi-record` rejected `--device-class ipad`, so the recorder could not capture the one device class ADR-009 lists as CONDITIONAL with an open evidence gap — the tool was unable to collect the evidence the docs were waiting on. `ipad` is now an accepted class, in the recorder, in the fixture meta schema (`docs/specs/testing.md` §3), and in the fixture-replay assertion that mirrors it.

### Added
- First tests for `Tools/rssi-record` (17, argument parsing only — no radio, no filesystem): the device- and Mac-class allow-lists, identifier canonicalisation and duplicate rejection, the scenario restriction that keeps an advertised name out of a fixture, duration bounds, and unknown/dangling flag handling. CI now runs `swift test --package-path Tools/rssi-record` alongside the existing build step; previously the maintained recorder was only ever compiled, which is how the iPad defect survived.
- Community health files: three issue forms (bug report asking for the de-identified diagnostics export; a trusted-device evidence report aimed at the open SPIKE-009 matrix; a proposal form), a pull-request template mirroring the CONTRIBUTING definition of done, `CODE_OF_CONDUCT.md`, and a social preview card committed with its HTML source so it can be regenerated rather than redrawn.

## [1.0.0-beta.1] - 2026-09-03

First public release. **Beta**: real-device evidence covers the primary path (iPhone as trusted device, Auto Lock, Wake on Return, Touch ID and Apple Watch native unlock), but the full SPIKE-009 device matrix, code signing/notarization, and a public trademark check are still open — see `docs/release-readiness-2026-09-03.md` for the exact state this tag ships in.

### Added
- MVP 0 — Engineering Foundation: SwiftPM package, Observation core types, `scripts/check-boundaries.sh`, CI, specs, ADRs, spike plans.
- Domain — observation: `ObservationValidator` (monotonic time, RSSI range, sentinel rejection), `DeviceID`, `MonotonicInstant`, `SensorStatus`.
- Domain — signal pipeline: `SignalWindow`, filters, `SignalEstimate` — RSSI to a filtered estimate with dispersion, no wall clock anywhere.
- Domain — presence: `PresenceScorer`, `AnyDeviceFusion`, presence types — confidence from a calibrated midpoint and slope.
- Domain — state machine: `ProximityEngine` with the three axes, transition causes, and plain-language state descriptions.
- Domain — calibration: near/far sampling session, `CalibrationStats`, `CalibrationValidator`, `CalibrationPolicy`, `DriftDetector`.
- Domain — policy: `PolicyEngine` with `RequiredPreconditions`, supporting evidence, idle guards and a settings gate; `ActionLedger` for proposal, outcome and retry accounting; every decision carries a `PolicyRationale`.
- Domain — regression corpus: 11 synthetic BLE fixtures under `Tests/Fixtures/BLE/` (stable-near, stable-away, walking-away, walking-back, device-lost, bluetooth-off, wake-after-sleep, signal-spike, wifi-interference, sudden-silence-at-desk, departure-then-silent), each with a `.expected.json` golden transition sequence and a replay harness that scans the directory.
- Bluetooth — `CoreBluetoothScanner` over the three-channel stream contract (observations, sensor status, discovery), `DeviceRegistry`, `CentralManaging` seam and `FakeScanner` for tests.
- System — clocks (`MonotonicClock`, `ContinuousMonotonicClock`, `FakeClock`); providers for screen, session, power and input activity, with a screen-state synthesizer over both the CoreGraphics query and the distributed notifications, plus fakes; lock and wake controllers (`pmset displaysleepnow` primary with an `IODisplayWrangler` `IORequestIdle` fallback — reordered 2026-09-03 after real-device testing found the IOKit path reports success without sleeping the display on this hardware — outcome confirmed against the screen provider; `IOPMAssertionDeclareUserActivity`); login item control; JSON-file stores for settings, devices, calibration and Mac identity.
- Diagnostics — ring buffer, `DiagnosticEvent`, `PrivacyFilter` with a sensitive-pattern list, device aliasing, and a fail-closed export that runs an anonymity check before writing.
- Runtime — `Coordinator` actor wiring scanner, engine, policy and system controllers; `DiagnosticsBridge`; `MonotonicBLEClock`; an L3 integration suite over the coordinator's event stream.
- App — `ThresholdAppKit` library (the `AppContainer` composition root, `AppModel`, onboarding and calibration state machines, discovery table, plain-language text) and the SwiftUI `MenuBarExtra` app: status line, degraded-state banner, first-launch onboarding, near/far calibration, settings, and de-identified diagnostics export.
- `Tools/rssi-record` — the MVP 1B field recorder. Drives the production `CoreBluetoothScanner`, writes anonymised JSONL fixtures, and prints the SPIKE-009 §C metrics (`receivingRatio`, `longestGapMs`, median and MAD RSSI). Includes the user-run field protocol for the remaining SPIKE-009 matrix.
- `Tools/spikes/` — throwaway probes `ble-observe` (SPIKE-009/004), `screen-state` (SPIKE-001/007/008) and `wake-display` (SPIKE-003). Raw output under `Tools/spikes/out/` is gitignored.
- `scripts/make-app-bundle.sh` — assembles `Threshold.app` from the SwiftPM executable, deriving the version from `CHANGELOG.md` and linting the generated Info.plist.
- CI — boundary check, build, test, app bundle and `Tools/rssi-record` build on every pull request.
- `docs/release.md` — the full path from a clean checkout to a distributable `.app`, with signing and notarization recorded as an external blocker.

### Changed
- Spike documents carry their 2026-09-02 evidence. SPIKE-009, 004, 001, 007 and 003 move from NOT RUN to PARTIAL with measurements and an explicit not-yet-measured list; SPIKE-008 moves to CONDITIONAL GO after the idle probe was corrected to `kCGAnyInputEventType` and `.hidSystemState` was chosen over `.combinedSessionState`.
- Specs amended: `proximity-domain.md` §6.2 (the snippet now lists `AcknowledgeResult.failed`, which §6.4 already required) and §7.3 (the default-profile gate short circuit, so a persisted placeholder can never arm). `system-integration.md` §1 records the SPIKE-001 finding that a missing `CGSSessionScreenIsLocked` key means unlocked rather than unknown, and the SPIKE-008 choice of `.hidSystemState`; §4's display-asleep row moves from expectation to measurement.
- ADR-011 amended: Xcode is now installed on the development machine and the decision stands; the App layer is split so `ThresholdAppKit` is testable under `swift test`.
- ADR-009 amended with the evidence status and the wording rule for user-facing text (「已觀察到」, not 「支援」, until the device matrix is run).

[Unreleased]: https://github.com/yusyuan9224/threshold/compare/v1.0.0-beta.1...HEAD
[1.0.0-beta.1]: https://github.com/yusyuan9224/threshold/releases/tag/v1.0.0-beta.1
