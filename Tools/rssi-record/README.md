# `rssi-record`

The MVP 1B field recorder. It turns a real device sitting on a real desk into an
anonymised replay fixture under `Tests/Fixtures/BLE/`, and into the SPIKE-009 §C
numbers that decide the supported device list.

Unlike the probes in `Tools/spikes/`, this tool is **maintained**: the fixtures it
writes are the engine's replay corpus, so it has to keep building.

It drives the production `ThresholdBluetooth.CoreBluetoothScanner`. There is no
second CoreBluetooth code path here on purpose — evidence gathered through a
throwaway scanner tells you about the throwaway scanner, not about the app.

## Build and run

```bash
cd Tools/rssi-record
swift build
.build/debug/rssi-record --help
```

The first run raises the macOS Bluetooth permission prompt for whatever process is
hosting the tool — usually your terminal, not the binary. Grant it under
System Settings › Privacy & Security › Bluetooth. If access is denied the tool
prints the `SensorStatus` it received and exits non-zero rather than hanging.

## `discover`

```bash
.build/debug/rssi-record discover 20
```

Prints one row per advertising device: identifier, advertised name, median RSSI,
sighting count, most-heard first. Expect twenty to sixty rows in a normal home or
office — SPIKE-009 saw 56 identifiers in ten minutes, a fifth of them alive for
under ten seconds.

Pick the row whose name and RSSI match the device in your hand, and note the
identifier.

> **The identifier is for local use only.** It goes into the next command and
> nowhere else. Never paste one into a fixture, a commit message, an issue, a spec
> or a chat message. The tool never writes this table to a file.

## `record`

```bash
.build/debug/rssi-record record \
  --device 12345678-90AB-CDEF-1234-567890ABCDEF \
  --scenario desk-1m \
  --mac-class laptop \
  --device-class iphone \
  --seconds 1200 \
  --out ../../Tests/Fixtures/BLE/desk-1m.jsonl
```

`--device` may be repeated; the devices are mapped to `device-A`, `device-B`, … in
command-line order, and only those aliases reach the file. Every ten seconds a
one-line progress report goes to stderr, so you can tell from across the room
whether the device is still being heard. Ctrl-C stops early and still writes the
fixture. The tool refuses to overwrite an existing `--out` path, and checks that
before it starts scanning rather than after.

### Fixture format

JSONL, per `docs/specs/testing.md` §3. Line one is metadata, then one line per
`EngineInput` with `t` in milliseconds since `t0`, then a summary line.

```jsonc
{"kind":"meta","macClass":"laptop","deviceClass":"iphone","scenario":"desk-1m","recorder":"rssi-record 0.1","anonymized":true,"durationMs":1200431}
{"kind":"sensor","t":24,"status":"available"}
{"kind":"observation","t":75,"device":"device-A","rssi":-54}
{"kind":"sensor","t":840112,"status":"degraded.scanInterrupted"}
{"kind":"summary","durationMs":1200431,"windowMs":10000,"sensorEvents":3,"devices":[{"device":"device-A","samples":1142,"droppedInvalidRSSI":5,"windows":121,"windowsWithSamples":121,"receivingRatio":1.0000,"longestGapMs":1206,"medianRSSI":-57,"madRSSI":4}]}
```

- `status` is `available`, `degraded.<reason>` or `unavailable.<reason>`, where the
  reasons are the `DegradedReason` / `UnavailableReason` cases:
  `resetting`, `scanInterrupted`, `poweredOff`, `unauthorized`, `unsupported`,
  `scannerFailed`.
- Event lines are written in non-decreasing `t`. The two channels are stamped from
  one clock but delivered on two tasks, so the recorder buffers and sorts before
  writing.
- RSSI `127` is CoreBluetooth's "value unavailable" sentinel, not a reading. Those
  samples are dropped and counted in `droppedInvalidRSSI`; SPIKE-009's first run
  did not filter them and its `max` column was unusable as a result.
- The summary carries the SPIKE-009 §C metrics and **no identifiers and no names**,
  so it can be quoted straight into the spike write-up.
  - `receivingRatio` — fraction of 10 s windows containing at least one sample.
  - `longestGapMs` — longest silent stretch, **including the head and tail of the
    run**. A device first heard four minutes in was silent for four minutes.
  - `medianRSSI`, `madRSSI` — lower median (`sorted[count / 2]`) and the median
    absolute deviation from it, in dB.

### Privacy rule

Fixtures committed under `Tests/Fixtures/BLE/` must pass
`scripts/check-boundaries.sh`: no UUIDs, no MAC addresses, no advertised names, no
wall-clock time. The tool is built so this holds by construction — identifiers and
names never reach the writer — but run the script before committing anyway:

```bash
./scripts/check-boundaries.sh
```

`--scenario` is the only free text that reaches the file, and it is restricted to
lowercase letters, digits and hyphens so a device name cannot slip in through it.

## Field protocol

Run these with the Mac awake and plugged in, and keep the recorder in the
foreground. Record what you did in `docs/spikes/SPIKE-009-trusted-device-observability.md`
under Evidence: the tool captures the signal, not the circumstances, and SPIKE-009's
first round is thin precisely because distance, screen state and lock state were
never written down.

### §A Device discovery matrix

One `record` run per row, 5 minutes each unless noted. For each, note in the spike
whether the device was found at all and how long the first sighting took.

- [ ] Mac screen on × device screen on × device unlocked × on the desk
- [ ] Mac screen on × device screen off × device locked × on the desk
- [ ] Mac screen off (display sleep) × device screen off × device locked × on the desk
- [ ] device in a pocket, screen off, locked
- [ ] device idle 5 min, then 30 min, then 60 min — `--scenario device-locked-idle-30m`
      for the long one, 30 minutes of `--seconds 1800`
- [ ] the same, for each device class you intend to support
      (`--device-class iphone`, then `watch`, then `beacon`)

### §B Identity stability

Run `discover 20` before and after each event below, and record whether the
identifier for your device is the same string. This needs no recording, only the
two tables.

- [ ] scanner restart (run `discover` twice, a minute apart)
- [ ] tool restart
- [ ] Mac reboot
- [ ] device reboot
- [ ] Bluetooth off → on, on the Mac
- [ ] Bluetooth off → on, on the device
- [ ] forget / re-pair
- [ ] 24 hours idle
- [ ] macOS update, if one lands during the window

If the identifier changes at any of these, say so plainly in the spike: it is a
`DeviceRegistry` problem, not a recorder problem, and it decides whether the
supported list survives.

### §C Presence suitability

Twenty minutes at each distance, one file each. Measure the distance rather than
estimating it, and write it in the spike.

- [ ] `--scenario desk-1m --seconds 1200` — device on the desk, 1 m
- [ ] `--scenario pocket-3m --seconds 1200` — device in a pocket, 3 m, you seated
- [ ] `--scenario next-room-8m --seconds 1200` — device in the next room, 8 m,
      through one wall

Read the summary line of each file. The SPIKE-009 success criterion is
`receivingRatio ≥ 0.95` and `longestGapMs ≤ 10000` at 1 m and 3 m. The 8 m run is
the one that has to *fail* for the far threshold to mean anything.

### Behaviour fixtures

The engine's regression set (`docs/specs/testing.md` §3) also wants these, and they
are recorded the same way — the scenario name is what tells them apart:

- [ ] `walking-away` — start at the desk, walk out, keep going for the full run
- [ ] `walking-back` — start outside, walk in, sit down
- [ ] `bluetooth-off` — turn the Mac's Bluetooth off mid-run and back on; the
      `unavailable.poweredOff` and `available` sensor lines are the point of the file
- [ ] `wake-after-sleep` — put the Mac to sleep mid-run and wake it; the recorder
      uses `ContinuousClock`, so the sleep shows up as a real gap rather than
      vanishing

Each recorded fixture needs a `.expected.json` golden transition sequence before it
can be used in replay (testing.md §3). That is the engine's job, not this tool's.
