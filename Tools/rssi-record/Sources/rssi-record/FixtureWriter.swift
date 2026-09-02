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

    /// Refuses to clobber an existing file, and refuses a path whose directory does
    /// not exist. A field run costs the operator real time, and a recording that
    /// cannot be reproduced must not be lost to an overwrite or a typo'd directory.
    /// Called before scanning starts as well as at write time.
    static func checkWritable(_ path: String) throws {
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
    }

    static func write(lines: [String], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try checkWritable(path)
        let contents = lines.joined(separator: "\n") + "\n"
        guard let data = contents.data(using: .utf8) else {
            throw ToolError("could not encode the fixture as UTF-8")
        }
        try data.write(to: url, options: .withoutOverwriting)
    }
}
