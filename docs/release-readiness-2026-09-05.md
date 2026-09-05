# v1.0 Readiness Report — 2026-09-05

Lead-agent report at main `c18b157`. Supersedes `docs/release-readiness-2026-09-03.md`, which stays
in the tree unchanged as the frozen record of the state the `v1.0.0-beta.1` tag shipped against.

Every number below is from a clean run on 2026-09-05, reproducible from this checkout. Nothing is
asserted about behaviour that was not measured.

**Verdict: v1.0 is not reached.** Two of the eighteen conditions are blocked on credentials and a
legal check the repository cannot perform for itself, and one is blocked on hardware measurements
that need an operator present. Everything reachable without those is done and verified. §9 states
this condition by condition rather than in prose.

## 1. Build / test commands and results (clean, 2026-09-05)

| Command | Result |
|---|---|
| `swift package clean && scripts/check-boundaries.sh` | `boundaries OK`, exit 0 |
| `swift build` | `Build complete!`, **0 warnings** |
| `swift test` | **577 tests in 85 suites passed**, exit 0 |
| `swift test --package-path Tools/rssi-record` | **17 tests in 4 suites passed**, exit 0 — new this report |
| `scripts/make-app-bundle.sh release` | `build/Threshold.app (version 1.0.0-beta.1, release)`, Info.plist lint OK |
| `swift build --package-path Tools/rssi-record` | `Build complete!` |
| `swift build --package-path Tools/app-smoke` | `Build complete!` |
| `app-smoke 15` (real adapters, headless) | Coordinator started with an empty registry; discovery idle→scanning→found in 591 ms; sensor health `initializing`→`healthy`; 4 Coordinator events recorded, **0 dropped**; providers read `screen=unlocked, session=active, power=awake`; nothing written to the user's Application Support; exit 0 |
| `git status --short --branch` | clean, `main...origin/main` in sync |

Toolchain: macOS 26.6.2, Xcode 26.6, Swift 6.3.3. Package tools-version 6.0, deployment target
macOS 14.0, **no external dependencies**.

CI (`.github/workflows/ci.yml`, macos-15) green on this commit:
[run 33943426312](https://github.com/yusyuan9224/threshold/actions/runs/33943426312) — toolchain,
shell-script lint, architecture boundaries, build, test, app bundle, Tools build, **Tools test**.
One non-blocking annotation: `actions/checkout@v4` targets Node 20, which GitHub has deprecated and
now force-runs on Node 24. Upgrading to `@v5` clears it; it does not affect any result above.

Test layers: L1 Domain unit (Signal / Presence / StateMachine / Policy / Calibration, including the
T-15 property test at 100k steps), L2 fixture replay (11 synthetic recordings with goldens), L3
Coordinator integration (T-03/07/08/09/12/18 plus lifecycle / restart / stop), ThresholdAppKit
end-to-end (FakeScanner → exactly one lock → ledger confirmed), L4 System adapter mapping and
fail-closed tests, Bluetooth T-18/T-19 concurrency, Diagnostics privacy and fail-closed export, and
now the `rssi-record` argument contract.

### Version resolution, checked

`scripts/make-app-bundle.sh` derives `CFBundleShortVersionString` from the first numeric
`## [x.y.z]` heading in `CHANGELOG.md`, so the bundle reports `1.0.0-beta.1`. `app-smoke` reports
`app_version: 0.1.0` — **not a defect**: it runs headless with no bundle, and
`AppContainer.bundleShortVersion()` deliberately falls back to an obviously-development string
rather than one that could be mistaken for a release inside a diagnostics export
(`Sources/ThresholdAppKit/AppContainer.swift:291`).

## 2. What changed since the beta tag

Two commits, both verified above.

**`e0f0e4d` — community health files.** The repository went public with only a CI workflow under
`.github/`, so every issue arrived as a blank box. Three issue forms, a pull-request template
mirroring the CONTRIBUTING definition of done, `CODE_OF_CONDUCT.md`, and a 1280×640 social preview
card committed with its HTML source. The device-evidence form is the substantive one: it targets the
open SPIKE-009 matrix, points at the `rssi-record` protocol, and asks for the tool's own metric
columns against the §C bar. Every form requires an explicit confirmation that no identifier was
pasted — the rule `check-boundaries.sh` enforces on fixtures, applied to the one surface a script
cannot police.

**`c18b157` — a real defect, found while writing that form.** `RecordOptions.deviceClasses` was
`["iphone", "watch", "beacon"]`, so `rssi-record --device-class ipad` was rejected — the recorder
could not capture the one class ADR-009 lists as CONDITIONAL with an open evidence gap. The tool was
unable to collect the evidence the documentation was waiting on. Fixed in all four places carrying
the list (recorder allow-list, usage string, the fixture meta schema in `docs/specs/testing.md` §3,
and the mirrored fixture-replay assertion), with each side now commenting the other and a test
pinning the pair.

The more important half of that commit is that **`rssi-record` had no tests at all**. Its own
manifest calls it MAINTAINED — its output is the engine's replay corpus and the SPIKE-009 evidence —
yet CI only ever compiled it, and a build cannot catch a wrong allow-list. That is precisely how the
defect survived. 17 tests now cover the argument contract (both allow-lists, identifier
canonicalisation and duplicate rejection, the scenario restriction that keeps an advertised name out
of a fixture, duration bounds, unknown and dangling flags). Parsing only — no CoreBluetooth, no
filesystem, no clock — so it runs on a hosted runner with no radio. CI gained a `Tools test` step.

## 3. Spike outcomes

| Spike | Result | Evidence (`docs/spikes/`) |
|---|---|---|
| 009 Trusted device observability | **PARTIAL** — iPhone CONDITIONAL GO, Watch conditional (near only), iPad conditional | Controlled 1 m / 3 m / 8 m run (600 s each, iPhone locked and screen off, Watch worn): iPhone 100% receiving at all three, RSSI monotonic (−50 / −60 / −68); Watch 98.4% / 100% near but **83.6% with a 25.7 s gap at 8 m**, failing the ≤10 s criterion. iPhone identifier unchanged across Bluetooth off→on at both ends and a full power cycle. iPad has only an earlier 1 h uncontrolled-distance run. Beacons, and the reboot / forget-re-pair matrix for Watch and iPad, not run |
| 004 CoreBluetooth lifecycle | **PARTIAL** — display-sleep and Bluetooth off→on both GO | Scan continues through display sleep (75 s + 136 s) and a real Mac-side Bluetooth off→on (35.6 s outage, correctly surfaced as `unavailable.poweredOff`, not device silence); resumes without re-issuing `scanForPeripherals`; identifier unchanged. System sleep, App Nap and 24 h not run |
| 001 Screen lock state | **PARTIAL** | 4/4 events: notification trails the query by 7–107 ms, no mismatch; `CGSSessionScreenIsLocked` absent == unlocked |
| 003 Wake behaviour | **PARTIAL** (toward GO) | Locked + display asleep: `IOPMAssertionDeclareUserActivity` lit the display 3/3 in ≤150 ms in isolation, confirmed again inside the real end-to-end wake dispatch. No wake-from-system-sleep claim (`docs/specs/system-integration.md` §4) |
| 007 Lock method | **PARTIAL, split by strategy** | `pmset displaysleepnow`: **GO**, 16/16 real samples, 41–337 ms, including one real end-to-end departure. IOKit `IORequestIdle`: **NO-GO on this hardware**. Paths ③④ untested; ② excluded (needs Accessibility) |
| 005 Apple Watch unlock | **CONDITIONAL GO** | 9/9 native Watch unlocks, 0 failures, including 2 with Threshold's own scan running (no interference observed). The app's own wake path has not yet been the trigger under test |
| 006 Touch ID interaction | **GO** (built-in keyboard, n=5) | 5/5 one-tap unlocks, 370–624 ms, no extra keypress. External Touch ID keyboard untested |
| 008 Input idle | **CONDITIONAL GO** | `.hidSystemState` + `kCGAnyInputEventType`; resets on real input after unlock; not reset by lock-screen input; `.combinedSessionState` is reset by our own wake call → rejected |
| 002 loginwindow | NOT RUN | MVP 6 only (Assisted Unlock, not in v1.0) |

Decisions are propagated into `bluetooth.md` §1/§4, `system-integration.md` §1/§2/§4, ADR-009,
ADR-011, `SupportedDevices.swift` onboarding copy, and both READMEs. No NO-GO has been bypassed with
a private API: the one NO-GO result (IOKit `IORequestIdle`) was answered by reordering to the proven
public path, not by reaching for something undocumented.

## 4. Supported-device matrix

| Class | Verdict | Evidence | Not yet measured |
|---|---|---|---|
| **iPhone** (same Apple ID) | **CONDITIONAL GO** — primary | 100% receiving at 1 m / 3 m / 8 m including through a closed door; longest gap 10.2 / 9.9 / 9.0 s; median RSSI −50 / −60 / −68, monotonic and separable; identifier unchanged across ~22.5 h, both-end Bluetooth off→on, and a full power cycle | `desk-1m`'s 10.2 s slightly exceeds the ≤10 s bar; reboot and forget/re-pair; a 20-minute-per-segment rerun |
| Apple Watch (same Apple ID) | **CONDITIONAL — near distance only** | 1 m 98.4%, 3 m 100%, longest gap ≤9.9 s | **8 m: 83.6% receiving, 25.7 s longest gap, 13 gaps over 10 s — fails the criterion.** RSSI non-monotonic (1 m median −59, 3 m median −41), unusable for calibration. Not a reliable sole signal for departure |
| iPad (same Apple ID) | **CONDITIONAL** | 1 h uncontrolled distance: 100% receiving, 9.9 s longest gap; identifier unchanged across ~22.5 h | Distance segments, reboot, Bluetooth off→on, forget/re-pair. **The recorder now accepts `--device-class ipad`, so these are collectable** — until `c18b157` they were not |
| Generic BLE beacon | UNKNOWN — not listed | — | Everything |
| Another Mac / AirPods | Observed only, not listed | Intermittent (33% / 48% of windows) | — |

Onboarding copy (`SupportedDevices.swift`) and both READMEs state this explicitly, including that
the Watch should be paired with a phone rather than relied on alone — a direct application of
ADR-008 to device selection.

## 5. Security and architecture conditions

Independent security review (read-only, on `main`): PASS on all ten checks — no password handling,
no private frameworks, undocumented screen signals confined to `ThresholdSystem`, fail-closed
preconditions (unknown → indeterminate blocks both lock and wake; nil idle blocks silence-lock
only), fixed-argv `pmset` with no shell, atomic JSON stores with typed decode errors, diagnostics
aliasing plus fail-closed export, fixtures free of identifiers, Bluetooth-only permission, no
external packages, stale outcomes never re-dispatched. `scripts/check-boundaries.sh` enforces the
same six boundaries in CI and is green on this commit.

The raw BLE → effect path is unchanged by everything in §2:

```text
BLEObservation → ObservationValidator → SignalPipeline → PresenceScorer → AnyDeviceFusion
  → ProximityEngine → ProximitySnapshot → PolicySnapshot → PolicyEngine → ActionLedger
  → Coordinator dispatch → LockControlling / WakeControlling
```

No shortcut exists. Neither commit in §2 touches this path: one adds Markdown and YAML, the other
widens a validation allow-list in a build-time tool that never runs inside the app.

## 6. Known limitations

- Wake on Return works only while the Mac is awake with the display asleep or locked. **No wake from
  full system sleep** — by design; no third-party app has a supported mechanism.
- Apple Watch loses reliable observability past ~8 m (83.6% receiving, 25.7 s longest gap). Listed
  as supported, but as a near-distance witness only.
- IOKit `IORequestIdle` is confirmed non-functional on this Mac and OS; retained only as a secondary
  fallback pending evidence from other hardware.
- `EngineConfiguration.silentThreshold` (10 s) is crossed by real iPhone advertising gaps measured at
  the desk (10.2 s once in 774 samples). It cannot cause a false lock — `silenceLock` requires 180 s
  of continuous silence — but can cause avoidable `.silent` flapping. Unchanged: it needs its own ADR
  and a 20-minute-segment re-measurement, and moving it would move fixture goldens.
- Scanner stream failure is a bounded fail-closed shutdown (`.unavailable(.scannerFailed)`), not
  recovery.
- Silence-based lock depends on SPIKE-008 conditions; screen saver, fast user switching and
  synthetic-event cases are untested.
- `SMAppService` login-item behaviour needs a signed, installed bundle to verify. `app-smoke` reports
  `login_item: notFound`, which is the correct reading for an unsigned headless run, not a result.
- Bundle identifier defaults to `dev.threshold.app`; set `THRESHOLD_BUNDLE_ID` before distribution.

## 7. Remaining external blockers

1. **Signing and notarization.** Needs a Developer ID certificate, notarytool credentials and a team
   ID — none are in the repository and none can be manufactured here. Everything preparable without
   them is done and syntax-checked in CI: `scripts/sign-and-notarize.sh` (hardened runtime, notarize,
   staple, `spctl`; exits 2 without credentials) and `scripts/make-dmg.sh` (refuses an unstapled
   bundle). Process documented in `docs/release.md` §4.
2. **Trademark search** for the product name, before any non-beta release. Disclosed in both READMEs,
   the landing page and this report.
3. **Real-device measurements needing an operator**: Apple Watch and iPad reboot / Bluetooth-toggle /
   forget-re-pair identity scenarios; the iPad distance matrix; generic beacons; SPIKE-007 paths ③④;
   the 20-minute-per-segment rerun that would also settle `silentThreshold`.
4. **Two GitHub actions the maintainer must perform**: uploading `docs/social-preview.png` (a
   repository *setting*, with no API), and creating the `v1.0.0-beta.1` Release object — the tag is
   pushed, but `gh release` is denied by this workspace's tool policy and routing around that denial
   via `gh api` would defeat the point of the rule.

## 8. Defects

**No known P0 or P1 defects.**

One defect was found and fixed since the last report — `rssi-record` rejecting `--device-class ipad`
(§2). It was P2, not P0/P1: it blocked evidence collection rather than any shipped behaviour, and no
user-facing path could reach it.

The two P0 defects found by real-device testing before the beta (Auto Lock failing outright on a
wrong default strategy order; Wake never firing because a cached `power` field was only ever updated
by a notification that never fired) remain fixed, re-verified end to end on real hardware, and are
documented in `docs/release-readiness-2026-09-03.md` §2. All earlier review findings (2 CRITICAL, 2
HIGH, several MEDIUM across branches) were fixed and re-verified before merge; the remainder are
LOW/informational and recorded in code comments or specs.

## 9. The eighteen v1.0 conditions, one by one

| # | Condition | Status |
|---|---|---|
| 1 | Required v1.0 milestones complete | **Met.** MVP 0–4 complete and verified end to end on real hardware; MVP 5 is this public beta; MVP 6 (Assisted Typed Unlock) is explicitly not required |
| 2 | Blocking spikes have explicit results with evidence, propagated; no NO-GO bypassed with private APIs | **Partially met.** Every spike has an explicit status and its decision is propagated (§3). SPIKE-009 and 004 remain PARTIAL with their unmeasured lists stated. The one NO-GO was answered with a public path, not a private one |
| 3 | Supported-device list is evidence-based; SPIKE-009 complete for every claimed class | **Not met.** The list *is* evidence-based and each entry carries the spike's own verdict language, but SPIKE-009 is complete for no class: iPhone, Watch and iPad are all CONDITIONAL. **Blocked on operator-present measurement** (§7.3) |
| 4 | Repository builds with the supported toolchain | **Met** (§1), zero warnings |
| 5 | All applicable automated tests pass, exit 0 | **Met** — 577 + 17, exit 0 (§1) |
| 6 | Auto Lock uses the selected supported path and meets the reliability gate | **Met.** `pmset displaysleepnow` primary, 16/16 real samples, outcome confirmed against `ScreenStateProviding` rather than trusted |
| 7 | Wake implemented only within verified capabilities; no unproven system-sleep claim | **Met.** Display-asleep/locked wake measured ≤150 ms; the no-system-sleep boundary is stated in the spec, both READMEs and §6 |
| 8 | Raw BLE cannot directly trigger effects; layers stay separated | **Met** (§5), enforced by `check-boundaries.sh` in CI |
| 9 | Sensor failure / missing evidence cannot masquerade as absence | **Met.** Verified in unit tests and, since the beta, by a real 35.6 s Bluetooth outage surfacing as `unavailable.poweredOff` |
| 10 | Security preconditions fail closed; no path stores or types the login password | **Met** (§5) |
| 11 | No production dependency on private APIs | **Met.** Undocumented signals are confined to `ThresholdSystem`, each with a Fake and a spike; no private framework |
| 12 | Required behaviours have tests or documented real-device evidence | **Met** for Bluetooth, concurrency, persistence, diagnostics, calibration, lifecycle and effect staleness; the real-device half is recorded in the 09-03 report §2 and in `docs/spikes/` |
| 13 | Diagnostics and fixtures contain no identifying data | **Met**, enforced by `check-boundaries.sh` and by `rssi-record`'s write path, which now also has tests covering the scenario restriction |
| 14 | CI passes every check available | **Met** — green on `c18b157`, now including `Tools test` (§1) |
| 15 | User-facing onboarding, permissions, calibration, menu bar, degraded-state UX and device messaging implemented and verified | **Met.** Walked end to end on real hardware before the beta: onboarding → device picker → near/far calibration producing a real profile → live status, correct trusted-device name, and a fail-closed precondition banner that correctly held off action. Recorded in the 09-03 report §2 |
| 16 | Docs match the implementation | **Met.** Both READMEs, CHANGELOG, SECURITY, TRADEMARK, CONTRIBUTING/DCO and the relevant ADRs/specs were updated with this commit's changes; `CODE_OF_CONDUCT.md` added |
| 17 | Everything preparable without credentials is complete and verified | **Met**, with signing itself **blocked** (§7.1) — the scripts exist, fail closed, and are syntax-checked in CI |
| 18 | Clean git status and a final readiness report | **Met** — this document, at a clean tree in sync with `origin/main` |

**Blocked on the maintainer, not on engineering: 3 (hardware), 7.1 (credentials), 7.2 (legal).**
Nothing in this list is waiting on a decision that the repository, the toolchain or CI could make for
itself.
