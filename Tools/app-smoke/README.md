# `app-smoke`

A headless run of the **real** app. It boots the production `AppContainer` — the same
adapters, the same `Coordinator`, the same `OnboardingFlow` the UI drives — runs discovery
for a few seconds, and prints what the app believed, as JSON lines you can paste into a
review.

Unlike the probes in `Tools/spikes/`, this tool is **maintained**: it is how real-device
behaviour of the composition root gets checked on a Mac and recorded as evidence, so it has
to keep building.

There is no second wiring here on purpose. A smoke test that assembled its own graph would
tell you about that graph, not about the app. The one thing it changes is where the three
JSON stores live.

## Build and run

```bash
cd Tools/app-smoke
swift build
.build/debug/app-smoke --help
.build/debug/app-smoke 15
```

The first run raises the macOS Bluetooth permission prompt for whatever process is hosting
the tool — usually your terminal, not the binary. Grant it under System Settings › Privacy &
Security › Bluetooth. If access is denied the run still completes: the discovery state goes
to `blocked(unauthorized, …)` and the sensor axis reports `unavailable(unauthorized)`, which
is itself the thing worth verifying.

## What it verifies

1. **The container comes up.** `AppContainer.bootstrap()` and `start()` against production
   adapters, with the initial `AppModel` printed: protection status, sensor health,
   calibration gate, registry count, login-item status, startup issues.
2. **Scanning really is deferred (architecture.md §5.4).** The `initial` line reports
   `sensor_health: "initializing"` — the engine has not heard from the adapter, because no
   `CBCentralManager` exists yet and no permission prompt has appeared. The container has
   been started, with the Coordinator running, for that whole time.
3. **Onboarding discovery works on real hardware.** `OnboardingFlow.startScanning()` is the
   same call the picker's button makes; the run prints every `discoveryState` transition
   (`idle` → `scanning` → `found`, or `blocked`) with a timestamp, then the device table.
   `sensor_health` on the `after_discovery` line should have become `healthy`.
4. **The system providers answer.** Screen, session, power and input-idle, read the way the
   Coordinator reads them when it builds a `PolicySnapshot` (architecture.md §5.1).
5. **The pipeline produced events.** `CoordinatorEvent` kinds, counted per case.
6. **Shutdown is clean.** `stop()` runs to completion and the process exits 0.

## What it does **not** do

- **It never locks the screen or wakes the display.** `MacOSLockController` and
  `MacOSWakeController` are constructed, because they are part of the production graph, but
  nothing here calls them and no trusted device is ever registered, so the policy engine has
  nothing to act on. Auto Lock is not exercised by this tool.
- **No GUI.** No window, no menu bar item, no SwiftUI. Everything it reports is read off
  `AppModel` and `OnboardingFlow`, which is where the views read it from too — but the views
  themselves are not covered.
- **It never registers a device or saves a calibration profile.** Discovery runs to the
  picker and stops there. Everything past step 2 of onboarding is untested here.
- **It does not touch your real storage.** See below.
- **Notification-driven provider streams are not exercised.** An async `@main` drains the
  main dispatch queue, not a `CFRunLoop`, so the distributed and workspace notifications
  behind `ScreenStateProviding.changes` may not be delivered in this process. The tool
  reports the synchronous `current` query, which is what it claims to report. Lock/unlock
  transition behaviour belongs to the app and its tests, not here.

## Storage

Stores are pointed at a throwaway, per-run directory:

```text
$TMPDIR/threshold-app-smoke/run-<unix seconds>/
```

Your real `~/Library/Application Support/<bundle id>/` is never read and never written. The
path is checked before the container is built — a `$TMPDIR` resolving inside Application
Support is refused rather than used. In practice the directory is not even created: nothing
in a smoke run saves, and `JSONFileStore` creates its directory on first write.

This is why `AppContainer.live`/`bootstrap` take a `storageDirectory:`. Nothing in the
shipping app passes it, and it does not weaken the composition-root rule — `AppContainer` is
still the only place a concrete adapter or store is constructed.

## Output

One JSON object per line, all on stdout, including the error line — so a whole run captures
with a single redirect and replays through `jq`.

| `kind` | What it carries |
| --- | --- |
| `start` | run length, store directory, poll interval |
| `model` | `AppModel` at `phase` `initial` and `after_discovery` |
| `discovery_state` | one line per `OnboardingFlow.DiscoveryState` change, with `at_ms` |
| `notice` | the identifier warning below |
| `discovery_summary` | counts, final state, and the five most-heard devices |
| `providers` | screen, session, power, input idle (`null` is a real answer) |
| `coordinator_events` | `CoordinatorEvent` kinds, counted per case |
| `end` | `ok` |
| `error` | why the run stopped; exit code 1 |

> **`identifier_local_use_only` is for local use only.** Those are real BLE identifiers from
> the room you ran in. Pass one to `Tools/rssi-record record --device` if you need it, and
> nowhere else — never into a fixture, a commit message, an issue, a spec or a chat message.
> Redact them to their first few characters before pasting a run into a report.

### Two fields that need reading carefully

- **`median_rssi_dbm` is sampled, not exhaustive.** `DiscoveryTable` keeps only the latest
  RSSI per identifier, because that is all the picker draws. This tool polls it every 250 ms
  and takes the median of what it saw, so `rssi_samples` is a lower bound on `sightings`.
  Both numbers are printed. For a real RSSI distribution use `Tools/rssi-record`, which reads
  every advertisement.
- **`show_every_device: true`.** The picker hides unnamed identifiers by default (the
  SPIKE-009 noise floor), and the UI has a switch for showing them. The tool turns it on, so
  `total_seen` covers the whole room and rows named `unnamed` are expected.

`coordinator_events` counts are read back out of the `DiagnosticsRecorder`, not off
`Coordinator.events`: that stream has exactly one iterator — the container's — and a second
one here would take events away from the app under test. `DiagnosticsBridge` maps every
event case onto a distinct category, so reversing the mapping recovers the counts exactly.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | the run completed (a `blocked` Bluetooth state still counts) |
| 1 | the run stopped: bad arguments, an unusable store path, or a throw from the container |
