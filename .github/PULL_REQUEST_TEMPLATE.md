<!--
Small, well-scoped fixes are welcome directly. For a new feature, a new supported-device class,
or a change to an accepted ADR, please open a proposal issue first (CONTRIBUTING.md).
-->

## What this changes, and why

<!-- The behaviour before and after. If it fixes an issue, link it. -->

## How you know it works

<!--
Evidence, not assertion. Which test covers it, or which real-device measurement you ran.
If the change is to system-facing behaviour that no unit test can reach — a lock strategy, a
provider that reads a live system signal — say so explicitly and describe what you observed on
real hardware. Both P0 defects fixed before the beta were invisible to the entire test suite for
exactly that reason.
-->

## Checks

Run before every commit (`CONTRIBUTING.md`):

- [ ] `scripts/check-boundaries.sh`
- [ ] `swift build`
- [ ] `swift test`
- [ ] `scripts/make-app-bundle.sh debug` — only if the App target, `Package.swift`, or the bundle script changed

## Definition of done

- [ ] **Implementation**
- [ ] **Tests** — new behaviour has a test, or the PR says why it cannot have one
- [ ] **Documentation** — the spec/ADR/README lines that describe this behaviour now match it
- [ ] **Diagnostics** — if this changes a decision the user could ask "why?" about, the diagnostics record the reason
- [ ] **No known security regression**

## Boundaries

- [ ] No production path stores, types, or synthesizes the login password
- [ ] No private framework, and no Accessibility permission
- [ ] Any undocumented system signal is inside `ThresholdSystem`, with a Fake and a spike
- [ ] Fail-closed preconditions still fail closed — missing or unknown evidence never becomes confirmed absence
- [ ] No fixture under `Tests/Fixtures/BLE/` contains a UUID, MAC address, advertised name, or wall-clock timestamp
- [ ] If a spike document changed: no result was written before its experiment ran, and any `GO` / `CONDITIONAL GO` / `NO-GO` has evidence attached

## Sign-off

- [ ] Every commit is signed off (`git commit -s`) — this project uses DCO, not a CLA
