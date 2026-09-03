# v1.0 Recovery Roadmap (2026-09-02)

Status: Closed 2026-09-03 — all tasks merged; see docs/release-readiness-2026-09-03.md. Written by the lead agent after the recovery audit; updated as milestones close.
Goal: the 18 v1.0 conditions recorded in the session `/goal`.

## Recovered state (audit)
| Branch | Commits vs main | Uncommitted | Build/Test | Decision |
|---|---|---|---|---|
| feat/diagnostics | 5 | none | 33 tests green | review → merge |
| feat/domain-calibration | 4 | none | 84 tests green | review → merge |
| feat/domain-policy-engine | 1 | PolicyEngine + ActionLedger + 4 test files | 76 tests green | commit → review → merge |
| feat/bluetooth-scanner | 7 | none | 55 tests green | review → merge |
| feat/system-integration | 0 | Clock/ (protocol + production clock, no tests) | n/a | add FakeClock + tests → commit |
| main | — | spike tools (now committed 3c409a4) | — | — |

Spike raw data exists in `Tools/spikes/out/` (ignored) for SPIKE-009/004 (60 s + 600 s scans) and
SPIKE-001/008 (+ one display-sleep sample touching SPIKE-003/007). Docs still say NOT RUN.

## Progress log
- 2026-09-02 14:38 T3 calibration merged (5dd07ac). 14:40 T4 policy merged (f83312e). 14:45 T5 bluetooth merged (7c822b3).
  14:52 T2 diagnostics merged (1c9d487) after BLOCK→fix→re-review. main: 262 tests, boundaries OK.
- T1 spike evidence written (dd36b21, faa882e, ffdf2ef): SPIKE-009/004/001/007/003/008 PARTIAL with data;
  autonomous runs added SPIKE-003 (3/3 wake) and SPIKE-004 (display-sleep scan continuity).
- 15:05 T6 system merged (d43423f): clocks, providers, controllers, stores. 15:12 T7 engine merged + T10 rssi-record
  (104fbde). main: 456 tests. Engine follow-up (T-15 coverage of rows #6/#7) in progress on feat/domain-engine.
- 2026-09-03 02:00 T8 Coordinator committed (feat/runtime-coordinator, 21 L3 tests) → review MERGE AFTER FIXES
  (deadline epoch guard; event stream buffering). T9 App committed (feat/app, ThresholdAppKit 72 tests) → review
  MERGE AFTER FIXES (onboarding discovery must show Bluetooth-unavailable state). Fixes in progress.
- 07:50 docs/release.md merged (93cf791). Remaining docs (README/CHANGELOG/ADR-009/011/CONTRIBUTING) after wiring.
- Next: merge both → T9b wire Coordinator into AppContainer (10 seams listed in app-ui report) → full verification →
  docs → readiness report.

## Task graph
```text
T1  Spike evidence → SPIKE docs / README table / bluetooth.md §1 / system-integration.md §1,§4     [docs]
T2  Review + merge feat/diagnostics                                                                  [merge]
T3  Review + merge feat/domain-calibration                                                           [merge]
T4  Commit policy WIP → review → merge feat/domain-policy-engine                                     [merge]
T5  Review + merge feat/bluetooth-scanner                                                            [merge]
T6  System: Clock (+FakeClock, tests) → providers (Screen/Session/Power/InputActivity + Fakes)
    → controllers (Lock/Wake/LoginItem + Fakes) → stores                                            [feat/system-integration]
T7  Domain MVP 2: ObservationValidator, Signal pipeline, PresenceScorer/Fusion, ProximityEngine,
    synthetic fixtures + replay harness (T-01..T-16 regression IDs)                                  [feat/domain-engine]
T8  Runtime: Coordinator actor + CoordinatorEvent + diagnostics bridge; L3 integration tests         [feat/runtime-coordinator]
T9  App: AppContainer, menu bar, onboarding, device discovery UI, calibration UI, settings,
    degraded-state UX                                                                                [feat/app]
T10 Tools/rssi-record (MVP 1B) + user-run field protocol for the remaining SPIKE-009 matrix          [tools]
T11 Release docs, CHANGELOG, README supported-device matrix, signing/notarization as external blocker [docs]
T12 Final readiness report                                                                           [report]
```
Dependencies: T2–T5 independent of each other; T6/T7 branch from main and run in parallel with merges;
T8 needs T4+T5+T6+T7 merged; T9 needs T8; T11/T12 last.

## Escalation / external blockers (expected)
- SPIKE-009 device matrix scenarios that need a human carrying the phone (pocket / 3 m / next room / other
  Apple ID / Apple Watch / generic beacon). Tooling is provided; results are recorded only when run.
- Signing / notarization credentials.
