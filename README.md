# Threshold

English ｜ **[繁體中文](README.zh-TW.md)**

> A security-first macOS proximity application that automatically protects the Mac when the user leaves and prepares it for secure native authentication when the user returns.

**v1.0.0-beta.1** — working title **Threshold** (a trademark search is still pending before an official name). This is the first public release, and it is a **beta**: the primary path (an iPhone as the trusted device, Auto Lock, Wake on Return, native Touch ID / Apple Watch unlock) has real-device evidence, but the full SPIKE-009 device matrix, code signing / notarization, and a formal trademark check are still open — see [`docs/release-readiness-2026-09-03.md`](docs/release-readiness-2026-09-03.md) for the exact state this tag ships in. The project roadmap is maintainer-directed; ideas and pull requests are welcome, best started as an issue for anything non-trivial.

## About

Threshold locks your Mac automatically when you walk away with your iPhone, and hands the screen straight back to Touch ID or Apple Watch when you return — no companion app, no account, no cloud.

Most Bluetooth-proximity lock tools on macOS reach for whatever gets the job done fastest: private frameworks, an active Bluetooth *connection* to your phone (which readable as "this app is talking to my phone" and drains its battery), or synthesizing keystrokes to type your password for you. Threshold takes the slower, narrower path instead:

- **Observation only.** It reads your trusted device's Bluetooth advertisements — the same signal your AirPods use to show a battery level — and never connects to it. Your phone's Bluetooth radio never even sees this Mac.
- **No password handling, anywhere.** Threshold cannot type your login password and never stores it. When you return, it wakes the display and hands the actual authentication back to macOS: Touch ID, your Apple Watch, or your password, typed by you.
- **Fail closed, not fail open.** If the Bluetooth sensor's health is unknown, or the evidence for "you left" is too thin, Threshold does nothing — it never guesses. Missing evidence is never treated as evidence of absence (that's ADR-008, one of the project's three governing principles below).
- **No cloud, no account, no telemetry.** Everything runs on your Mac. There is nothing to sign up for and nothing being sent anywhere.
- **Public APIs only, everywhere it can be observed.** Every undocumented macOS signal Threshold reads is isolated to one module (`ThresholdSystem`) and backed by its own real-device measurement — see the spike table below. Nothing else in the codebase touches an undocumented signal, a private framework, or an Accessibility permission.

If that sounds like it should be simple, it mostly is — the complexity in this repository is almost entirely in *proving* each of those claims with real hardware rather than just asserting them. That evidence trail (the `docs/spikes/` directory, the diagnostics export, the readiness report) is deliberately kept alongside the code, not thrown away once a feature "works."

## Status (2026-09-03)

All six layers (Domain, Bluetooth, System, Diagnostics, Runtime, App) are implemented, `swift test` is fully green, and the app assembles into a runnable `Threshold.app`. A complete departure → lock → return → wake cycle has been verified end to end on real hardware. **Unconditional v1.0 is not yet reached**: signing credentials and part of the device matrix remain outside this repository.

| Item | Status |
|---|---|
| Implementation | Complete (Domain, Bluetooth, System, Diagnostics, Runtime, AppKit/App) |
| Automated verification | `check-boundaries.sh` + `swift build` + `swift test` + bundle; CI runs the same set on every PR, with a hosted green run on `main` |
| Real-device verification | **Primary path verified** — iPhone distance matrix (1 m / 3 m / 8 m), identity stability, Auto Lock, Wake on Return, Touch ID and Apple Watch unlock all measured on real hardware. Apple Watch / iPad reboot and forget-re-pair scenarios, and beacon support, are **not yet measured** — see the spike table below |
| Signing and notarization | **External blocker** — no credentials in the repo; `docs/release.md` §4 documents the exact steps and `scripts/sign-and-notarize.sh` / `scripts/make-dmg.sh` are prepared and fail closed without them |

## What the app does

```text
Presence Detection → Automatic Protection → Native Authentication Handoff
```

The app **never holds your login password, never types it, and never performs authentication itself**; authentication is always handed back to macOS (Touch ID / Apple Watch / password).

| Feature | Mechanism | Boundary |
|---|---|---|
| **Auto Lock** | After deciding the user has left, requests a lock via the display-sleep path (`pmset displaysleepnow`, with an IOKit `IORequestIdle` fallback), then **confirms the result against `ScreenStateProviding`** before calling it successful | If the user has not enabled "require password immediately after sleep," the display sleeps but does not lock — which is exactly why the outcome is confirmed rather than trusted |
| **Wake on Return** | Calls `IOPMAssertionDeclareUserActivity` to light the display and hand back the login screen when the user returns | **Only works while the Mac itself is awake, with the display asleep or locked. Threshold does not claim to wake the Mac from full system sleep** — no third-party app has a supported mechanism to do that (`docs/specs/system-integration.md` §4). Measured: display-sleep + locked wake succeeded 3/3 in ≤150 ms with no permission prompt and the lock state unchanged; the login screen re-sleeps after ~33 s of no input |
| **Diagnostics** | A ring buffer records transitions, decisions and their rationale so the UI can answer "why did it just lock?"; exportable as de-identified JSON | Sensitive patterns are filtered before export, and export fails closed if the filter can't confirm the result is clean |

Once the Mac enters full system sleep, the first key press or trackpad touch after that is the user's own — Touch ID and Apple Watch then take over as usual (measured: built-in Touch ID unlocked in 5/5 one-tap trials, 370–624 ms; Apple Watch unlocked in 9/9 trials, including 2 with Threshold's own Bluetooth scan actively running with no observed interference).

## Three principles (see docs/decisions)

1. Domain owns temporal rules but never owns time. (ADR-003)
2. Absence of evidence is not evidence of absence. (ADR-008)
3. A device is supported only if its presence can be observed reliably through supported APIs. (ADR-009)

## Privacy (ADR-007)

- **Local-only by default: no cloud, no account, no telemetry.** Nothing in this release depends on any cloud service.
- Diagnostics may never contain a password, any credential, or a full identifier/MAC address (a stable per-process alias `device-N` is used instead; the alias table itself is never exported).
- Exported files are de-identified, and an anonymity check runs before anything is written.
- The same rule applies to test fixtures: `scripts/check-boundaries.sh` rejects any fixture containing a UUID or MAC address; `rssi-record` never writes advertised names or wall-clock timestamps into a fixture in the first place.

## Build, test, package

```bash
scripts/check-boundaries.sh                  # architecture and privacy boundaries
swift build
swift test
scripts/make-app-bundle.sh release           # → build/Threshold.app
swift build --package-path Tools/rssi-record
```

Requirements: macOS 14.0+ (deployment target), Swift 6 language mode. Neither development nor CI needs an Xcode project — the app is a SwiftPM executable (ADR-011). The bundle produced by `make-app-bundle.sh` is **unsigned** and is not a distributable artifact; see `docs/release.md` for the release process.

| Target | Contents |
|---|---|
| `ThresholdDomain` | Pure logic: observation validation, the signal pipeline, presence scoring, the three-axis state machine, Policy, the ledger, calibration. Depends only on the standard library |
| `ThresholdBluetooth` | CoreBluetooth adapter, the three-channel stream contract, `DeviceRegistry`, a fake for tests |
| `ThresholdSystem` | macOS providers/controllers/stores — the only place an undocumented signal is allowed to appear (ADR-004) |
| `ThresholdDiagnostics` | Leaf target: ring buffer, privacy filter, export |
| `ThresholdRuntime` | The `Coordinator` actor, diagnostics bridge, wiring |
| `ThresholdAppKit` | The `AppContainer` composition root, `AppModel`, onboarding/calibration state machines |
| `ThresholdApp` | The SwiftUI `MenuBarExtra` and `@main` — nothing else |

## Tools

| Tool | Purpose |
|---|---|
| `Tools/rssi-record` | **Maintained.** The MVP 1B field recorder — drives the production `CoreBluetoothScanner`, writes anonymised real-device signal into replay fixtures under `Tests/Fixtures/BLE/`, and prints the SPIKE-009 §C metrics. Includes the field protocol for anyone completing the remaining SPIKE-009 matrix |
| `Tools/spikes/ble-observe` | Throwaway. The scanning probe behind SPIKE-009/004 |
| `Tools/spikes/screen-state` | Throwaway. The lock and idle probe behind SPIKE-001/007/008 |
| `Tools/spikes/wake-display` | Throwaway. The `IOPMAssertionDeclareUserActivity` probe behind SPIKE-003 |

Raw spike output lives under `Tools/spikes/out/` and is **gitignored**: it contains `CBPeripheral.identifier` values and advertised device names.

## Spike status

**No result is written before the experiment runs.** A spike with measurements but an incompletely verified success criterion is `PARTIAL`; every `PARTIAL` document carries an `## Evidence` section and an explicit "not yet measured" list.

| ID | Question | Gates | Order | Status |
|---|---|---|---|---|
| SPIKE-009 | Can the device classes we claim to support be observed reliably? | MVP 1A | **1** | PARTIAL (2026-09-03: iPhone CONDITIONAL GO; Watch near-distance only; iPad CONDITIONAL) |
| SPIKE-004 | CoreBluetooth lifecycle | MVP 1A | 1 (same batch) | PARTIAL — display-sleep and Bluetooth off→on both GO (2026-09-03) |
| SPIKE-001 | Screen lock state detection | MVP 3 | 2 (during MVP 2) | PARTIAL (2026-09-02) |
| SPIKE-007 | Lock method | MVP 3 | 2 | PARTIAL — `pmset` path GO (n=16/50, including one real end-to-end departure); IOKit `IORequestIdle` NO-GO on this hardware, default order corrected (2026-09-03) |
| SPIKE-008 | Input-idle detection | MVP 3 (silence policy) | 2 | CONDITIONAL GO (2026-09-02; `.hidSystemState`, nil while locked) |
| SPIKE-003 | Wake behaviour and the system-sleep boundary | MVP 4 | 3 (during MVP 3) | PARTIAL — display-sleep wake GO, confirmed again in a real end-to-end run (2026-09-03) |
| SPIKE-005 | Apple Watch unlock interaction | MVP 4 | 3 | CONDITIONAL GO — scan does not interfere, n=9 (2026-09-03) |
| SPIKE-006 | Touch ID interaction | MVP 4 | 3 | GO — built-in keyboard, n=5 (2026-09-03) |
| SPIKE-002 | loginwindow detection | MVP 6 | 4 (after MVP 5) | NOT RUN — MVP 6 only (Assisted Unlock, not in v1.0) |

## Supported devices (evidence-based, 2026-09-03)

Per ADR-009, only classes SPIKE-009 has evidence for are listed, labeled with the spike's own verdict language. The distance segments (1 m on the desk / 3 m in a pocket / 8 m in the next room behind a closed door) are a controlled measurement from the evening of 2026-09-03, 600 s each.

| Class | Verdict | Evidence | Not yet measured |
|---|---|---|---|
| **iPhone** (same Apple ID) | **CONDITIONAL GO** | 100% receiving at all three distances; longest gap 10.2 / 9.9 / 9.0 s; median RSSI −50 / −60 / −68, monotonic with distance and separable. **Locked, screen off, the whole time** — still 100% observable through a closed door at 8 m. Identifier unchanged across ~22.5 h | `desk-1m`'s 10.2 s slightly exceeds the ≤10 s bar; reboot, Bluetooth off→on, forget/re-pair; a 20-minute-per-segment version of this run |
| Apple Watch (same Apple ID) | **CONDITIONAL — near distance only** | 1 m: 98.4% / 9.9 s gap. 3 m: 100% / 7.1 s gap | **Fails at 8 m**: 83.6% receiving, 25.7 s longest gap, 13 gaps over 10 s. RSSI is non-monotonic (median −59 at 1 m, −41 at 3 m) — not usable for distance calibration |
| iPad (same Apple ID) | **CONDITIONAL** | 1 h, uncontrolled distance: 100% receiving, 9.9 s longest gap; identifier unchanged across ~22.5 h | Distance segments, reboot, Bluetooth off→on, forget/re-pair |
| Generic BLE beacon | UNKNOWN — not listed | — | Everything |
| Another Mac / AirPods | Observed only, not listed | Intermittent (33% / 48% of windows) | — |

What "CONDITIONAL" means: the SPIKE-009 §C bar (≥95% receiving, gap ≤10 s) is met under "same Apple ID, Bluetooth on"; the reboot/Bluetooth-toggle identity scenarios are still open. **Apple Watch's condition is narrower**: it's a good signal that you're nearby, but loses observability at leaving distance and should not be the sole signal that you've left — a direct application of ADR-008 ("absence of evidence is not evidence of absence") to device selection. All measurements are from a single Apple Silicon Mac (`Mac17,2`, M5) × macOS 26.6.2, `withServices: nil`, `allowDuplicates: true` — no companion app, service UUID, or connection required. The protocol for closing the remaining gaps is in `Tools/rssi-record/README.md`.

## Roadmap

| Milestone | Content | Status |
|---|---|---|
| MVP 0 | Engineering Foundation | Complete |
| SPIKE-009 | Trusted Device Observability (GO/NO-GO gate) | PARTIAL — primary path (iPhone) verified; secondary-device matrix outstanding |
| MVP 1A | BLE Discovery / Observation | Complete |
| MVP 1B | Recorded Field Data Collection | Tooling complete; real-device recording in progress |
| MVP 2 | Presence Engine | Complete |
| MVP 3 | Auto Lock | Implemented and verified end to end on real hardware |
| MVP 4 | Wake + Native Handoff | Implemented and verified end to end on real hardware |
| MVP 5 | Public Beta | **This release** — signing/notarization still pending |
| MVP 6 | Security Spike (Assisted Typed Unlock) | Not guaranteed to ship in v1 |
| v1.0 | Reliable + Secure + Diagnosable + Maintainable | — |

## Documentation map

| Location | Contents |
|---|---|
| `docs/specs/architecture.md` | Target boundaries, dependency direction, composition root, concurrency |
| `docs/specs/proximity-domain.md` | Domain model, signal pipeline, the three-axis state machine, Policy, ledger, calibration |
| `docs/specs/security.md` | Security boundaries, fail-closed rules, threat model, `UnlockSafetyGuard` (reserved) |
| `docs/specs/bluetooth.md` | CoreBluetooth adapter, the three-channel stream, Sendable contract |
| `docs/specs/system-integration.md` | macOS providers/controllers, lifecycle, sleep semantics |
| `docs/specs/testing.md` | The four test layers, fixtures, required regression tests, the real-device matrix |
| `docs/decisions/` | ADR-001 … ADR-011 |
| `docs/spikes/` | SPIKE-001 … SPIKE-009 and their evidence |
| `docs/plans/` | Implementation plans and the v1.0 recovery roadmap |
| `docs/release.md` | The full path from a clean checkout to a distributable `.app`; signing and notarization are an external blocker |
| `docs/release-readiness-2026-09-03.md` | The full v1.0 readiness report this beta ships against |

## License

Core license: Apache-2.0 (see LICENSE) + DCO + trademark protection (TRADEMARK.md). Details in ADR-005.
