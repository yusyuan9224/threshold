import Foundation
import ThresholdBluetooth
import ThresholdDomain

/// `rssi-record record …` — drives the production `CoreBluetoothScanner` and writes
/// an anonymised JSONL fixture (testing.md §3) plus the SPIKE-009 §C metrics.
enum RecordCommand {

    static func run(_ options: RecordOptions) async throws {
        // Checked before a single second of the operator's time is spent, not at
        // write time: discovering that the path was taken, or that the filename does
        // not match the scenario, *after* a thirty-minute walk-around is the worst
        // possible moment to find out.
        try FixtureWriter.checkWritable(options.outputPath, scenario: options.scenario)

        let clock = ContinuousBLEClock()
        let scanner = CoreBluetoothScanner(clock: clock)
        let devices = options.devices.map { DeviceID($0.uuidString) }
        // One `t0` for the fixture's `t` offsets, the stderr ticks and `durationMs`,
        // so the three can never disagree about when the run started.
        let t0 = clock.now()
        let recording = Recording(devices: devices, t0: t0)
        let watch = SensorWatch()

        for (index, _) in devices.enumerated() {
            note("  \(Recording.alias(at: index)) ← argument \(index + 1)")
        }
        note("Recording \(options.scenario) for \(options.seconds)s. Ctrl-C stops early and still writes the fixture.")

        // Creating the central — which `startScanning(for:)` does lazily — is what
        // raises the Bluetooth permission prompt (architecture.md §5.4). Nothing
        // before this line can hang on permission.
        scanner.startScanning(for: Set(devices))

        let (interrupts, source) = interruptSignal()
        defer { source.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await observation in scanner.observations {
                    await recording.add(observation)
                }
            }
            group.addTask {
                for await status in scanner.sensorStates {
                    await watch.note(status.value)
                    await recording.add(status)
                    let t = (status.at - t0).wholeNanoseconds / 1_000_000
                    note("[t=\(seconds(fromMs: t))s] sensor \(status.value.fixtureName)")
                    if status.value.isUnrecoverable {
                        // No amount of waiting clears this one, and the fixture would
                        // be empty. Fail loudly instead of recording nothing.
                        throw ToolError("Bluetooth is \(status.value.fixtureName) — cannot record")
                    }
                }
            }
            group.addTask { await tick(recording: recording, clock: clock, t0: t0) }
            group.addTask { try? await Task.sleep(for: .seconds(options.seconds)) }
            group.addTask {
                for await _ in interrupts {
                    note("Interrupted — writing what has been recorded so far.")
                    return
                }
            }
            // Whichever finishes first ends the run: the duration elapsing, a Ctrl-C,
            // or an unrecoverable sensor status (which rethrows here). Leaving the
            // group's scope cancels the rest.
            try await group.next()
            group.cancelAll()
        }

        scanner.stopScanning()

        if let reason = await watch.unusableReason() {
            throw ToolError("\(reason)\nNothing was written to \(options.outputPath).")
        }

        let durationMs = (clock.now() - t0).wholeNanoseconds / 1_000_000
        let metrics = await recording.summary(durationMs: durationMs)
        let lines =
            [FixtureWriter.metaLine(options, durationMs: durationMs)]
            + (await recording.lines())
            + [
                FixtureWriter.summaryLine(
                    durationMs: durationMs,
                    sensorEvents: await recording.sensorEventCount,
                    devices: metrics
                )
            ]

        try FixtureWriter.write(lines: lines, to: options.outputPath, scenario: options.scenario)
        report(metrics, path: options.outputPath, lineCount: lines.count)
    }

    /// One line to stderr every 10 s, so the operator can tell from across the room
    /// whether the device is still being heard.
    private static func tick(recording: Recording, clock: ContinuousBLEClock, t0: MonotonicInstant) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return  // cancelled
            }
            let elapsedMs = (clock.now() - t0).wholeNanoseconds / 1_000_000
            let progress = await recording.progress(elapsedMs: elapsedMs)
                .map { "\($0.alias) \(JSONLine.fixed($0.ratio * 100, places: 1))% (\($0.samples))" }
                .joined(separator: "  ")
            note("[t=\(seconds(fromMs: elapsedMs))s] \(progress)")
        }
    }

    private static func report(_ metrics: [DeviceMetrics], path: String, lineCount: Int) {
        note("")
        note("Wrote \(lineCount) lines to \(path)")
        note(row("device", "samples", "recv%", "maxGap s", "median", "MAD"))
        for device in metrics {
            note(
                row(
                    device.alias,
                    "\(device.samples)",
                    JSONLine.fixed(device.receivingRatio * 100, places: 1),
                    JSONLine.fixed(Double(device.longestGapMs) / 1000, places: 1),
                    "\(device.medianRSSI)",
                    "\(device.madRSSI)"
                )
            )
            if device.droppedInvalidRSSI > 0 {
                note("    dropped \(device.droppedInvalidRSSI) sample(s) with RSSI 127 (CoreBluetooth 'unavailable')")
            }
        }
        note("")
        note("Before committing under Tests/Fixtures/BLE/, run scripts/check-boundaries.sh.")
    }

    /// `String(format:)` is avoided for the text columns: `%s` takes a C string, not
    /// a Swift `String`, and getting that wrong is a crash rather than a bad column.
    private static func row(_ columns: String...) -> String {
        let widths = [12, 9, 9, 10, 8, 6]
        return "  " + zip(columns, widths)
            .map { $0.count >= $1 ? $0 : String(repeating: " ", count: $1 - $0.count) + $0 }
            .joined(separator: " ")
    }
}
