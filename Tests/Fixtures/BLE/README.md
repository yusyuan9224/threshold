# BLE fixtures (L2 replay)

Synthetic recordings replayed through `ProximityEngine` by `FixtureReplayTests`
(`docs/specs/testing.md` §1 L2, §3). Same input, same output, forever: any engine change that
moves one of these has to change the golden file and say why.

These are **synthetic** (MVP 2). `Tools/rssi-record` replaces them with real captures in MVP 1B;
the synthetic set stays as the minimal regression suite.

## Format

JSONL. The first line is metadata, every later line is one `EngineInput`. `t` is milliseconds
relative to t0, so a fixture carries no wall-clock and no `MonotonicInstant`.

```jsonc
{"kind":"meta","macClass":"laptop","deviceClass":"iphone","scenario":"stable-near",
 "recorder":"synthetic 1.0","anonymized":true,
 "profile":{"nearBaseline":-50,"farBaseline":-70,"noise":3,"midpoint":-60,"slope":5}}
{"kind":"sensor","t":0,"status":"available"}
{"kind":"observation","t":0,"device":"device-A","rssi":-45}
{"kind":"tick","t":26000}
{"kind":"reset","t":12000,"reason":"systemWake"}
{"kind":"summary","durationMs":1200431,"devices":[...]}            // optional, last line, skipped
```

`status` is exactly one of `available`, `degraded.resetting`, `degraded.scanInterrupted`,
`unavailable.poweredOff`, `unavailable.unauthorized`, `unavailable.unsupported`,
`unavailable.scannerFailed` — that is, `available` or `<case>.<reason.rawValue>`. The recorder and
the decoder both spell these by hand so the file format cannot drift when the Domain's enums change
shape. `FixtureFormatTests` pins every spelling.

`t` is non-decreasing. `Tools/rssi-record` closes a recording with a `summary` line of capture
metrics; it is not an input, so the replay skips it. Unknown metadata fields, such as the
recorder's `durationMs`, are ignored.

`profile` is the calibration the recording was made under. Goldens depend on it, so it travels with
the fixture instead of living in test code. A recording without one replays against
`CalibrationProfile.default`, which parses fine but makes for a meaningless golden: a real capture
that wants a golden needs its device's profile in the meta line. Everything else uses
`EngineConfiguration()` defaults.

A recording must open with a `sensor` line: the presence axis only advances while
`SensorHealth == .healthy`, and the engine starts in `initializing`.

Fixtures are discovered by scanning this directory, so dropping in a `<scenario>.jsonl` and its
`<scenario>.expected.json` is enough to add it to the regression set. The filename **is** the
scenario: a capture saved as `desk-1m.jsonl` must carry `"scenario":"desk-1m"`, so a golden can
never be matched against the wrong recording.

## Anonymisation

`DeviceID` is `device-` plus one or two uppercase letters, assigned in capture order: `device-A`,
`device-B`. No serial numbers, MAC addresses, device names or wall-clock timestamps. `scripts/check-boundaries.sh` fails the build on a UUID- or MAC-shaped
string anywhere under `Tests/Fixtures`.

## Goldens

Each `<scenario>.jsonl` has a `<scenario>.expected.json` holding the presence-axis transitions and
the final presence and evidence. Sensor- and device-axis transitions are deliberately not in the
golden: they are diagnostics, and pinning them would make every fixture brittle to changes that do
not affect what the system believes about the user.

## Scenarios

| Fixture | What it pins down |
|---|---|
| `stable-near` | Sitting at the desk: one confirmation, then nothing. |
| `stable-away` | Device in the next room: measured far, never near. |
| `walking-away` | present → departing → away on measured evidence. |
| `walking-back` | away → present after the full confirm cost. |
| `signal-spike` | T-01: one reflected advertisement changes nothing. |
| `device-lost` | Gentle weakening, then silence: evidence expires, never away. |
| `bluetooth-off` | T-03: the radio dies mid-session and presence is frozen, not moved to away. |
| `departure-then-silent` | T-14: weakening then silence yields away with its provenance intact. |
| `sudden-silence-at-desk` | T-13: strong signal, instant silence, user still there → evidenceExpired. |
| `wake-after-sleep` | T-08: the wake reset costs the full minSamples + confirmDuration again. |
| `wifi-interference` | A noisy band produces no spurious departure. |
