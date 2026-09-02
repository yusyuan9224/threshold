import Foundation
import ThresholdDomain

/// Assembles the JSONL fixture: meta line, event lines, summary line.
///
/// Nothing here takes an identifier or an advertised name as input. That is the
/// privacy boundary of the tool (testing.md §3, `scripts/check-boundaries.sh` §6):
/// the mapping from `CBPeripheral.identifier` to `device-A` exists only in the
/// operator's terminal and in `Recording`'s in-memory table, and is never written.
enum FixtureWriter {
    static let recorderVersion = "rssi-record 0.1"

    static func metaLine(_ options: RecordOptions, durationMs: Int64) -> String {
        var pairs: [(String, String)] = [
            ("kind", JSONLine.str("meta")),
            ("macClass", JSONLine.str(options.macClass)),
            ("deviceClass", JSONLine.str(options.deviceClass)),
            ("scenario", JSONLine.str(options.scenario)),
            ("recorder", JSONLine.str(recorderVersion)),
            ("anonymized", JSONLine.bool(true)),
            ("durationMs", JSONLine.int(durationMs)),
        ]
        // Omitted entirely when absent rather than written as null: the replay's
        // `profile` is optional, and a missing key is what tells it to fall back.
        if let profile = options.profile {
            pairs.append(("profile", profileObject(profile)))
        }
        return JSONLine.object(pairs)
    }

    /// The calibration the recording was made under. The replay arms its calibration
    /// gate with this, so it travels with the fixture instead of living in test code.
    private static func profileObject(_ profile: CalibrationProfile) -> String {
        JSONLine.object([
            ("nearBaseline", JSONLine.number(profile.nearBaseline)),
            ("farBaseline", JSONLine.number(profile.farBaseline)),
            ("noise", JSONLine.number(profile.noise)),
            ("midpoint", JSONLine.number(profile.midpoint)),
            ("slope", JSONLine.number(profile.slope)),
        ])
    }

    /// SPIKE-009 §C metrics. Aliases only — the whole point of putting the summary in
    /// the fixture is that it can be read and quoted in the spike write-up without
    /// anyone having to open a file that names a device.
    static func summaryLine(
        durationMs: Int64,
        sensorEvents: Int,
        devices: [DeviceMetrics]
    ) -> String {
        JSONLine.object([
            ("kind", JSONLine.str("summary")),
            ("durationMs", JSONLine.int(durationMs)),
            ("windowMs", JSONLine.int(Recording.windowMs)),
            ("sensorEvents", JSONLine.int(sensorEvents)),
            ("devices", JSONLine.array(devices.map(deviceObject))),
        ])
    }

    private static func deviceObject(_ metrics: DeviceMetrics) -> String {
        JSONLine.object([
            ("device", JSONLine.str(metrics.alias)),
            ("samples", JSONLine.int(metrics.samples)),
            ("droppedInvalidRSSI", JSONLine.int(metrics.droppedInvalidRSSI)),
            ("windows", JSONLine.int(metrics.windows)),
            ("windowsWithSamples", JSONLine.int(metrics.windowsWithSamples)),
            ("receivingRatio", JSONLine.fixed(metrics.receivingRatio, places: 4)),
            ("longestGapMs", JSONLine.int(metrics.longestGapMs)),
            ("medianRSSI", JSONLine.int(metrics.medianRSSI)),
            ("madRSSI", JSONLine.int(metrics.madRSSI)),
        ])
    }

    /// Refuses to clobber an existing file, refuses a path whose directory does not
    /// exist, and refuses a filename that disagrees with `--scenario`.
    ///
    /// A field run costs the operator real time, so all three are checked before
    /// scanning starts as well as at write time. Losing a thirty-minute walk-around
    /// to a typo'd directory, or finding out afterwards that the file cannot be used
    /// as a fixture, is the worst possible moment to learn either.
    static func checkWritable(_ path: String, scenario: String) throws {
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("\(path) already exists — pick another --out path")
        }
        let directory = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ToolError("\(directory) is not a directory")
        }

        // The replay scans `Tests/Fixtures/BLE` and matches `<scenario>.jsonl` to
        // `<scenario>.expected.json`, so the filename *is* the scenario: a capture
        // saved under one name carrying another in its meta line can never be used,
        // and the engine's metadata test rejects it. Enforced here rather than left
        // to the operator, because the cost of the mistake is a whole run.
        let name = url.deletingPathExtension().lastPathComponent
        guard name == scenario else {
            throw ToolError(
                """
                --out names the file \(name).jsonl but --scenario is \(scenario). The \
                filename is the scenario: the replay matches \(scenario).jsonl to \
                \(scenario).expected.json. Use --out …/\(scenario).jsonl, or change \
                --scenario to \(name) if that is what you meant to record.
                """
            )
        }
        guard url.pathExtension == "jsonl" else {
            throw ToolError("--out must end in .jsonl (the replay only scans for \(scenario).jsonl)")
        }
    }

    static func write(lines: [String], to path: String, scenario: String) throws {
        let url = URL(fileURLWithPath: path)
        try checkWritable(path, scenario: scenario)
        let contents = lines.joined(separator: "\n") + "\n"
        guard let data = contents.data(using: .utf8) else {
            throw ToolError("could not encode the fixture as UTF-8")
        }
        try data.write(to: url, options: .withoutOverwriting)
    }
}
