/// Maps raw device identifiers (MAC-like addresses, CoreBluetooth peripheral identifiers, advertised
/// names, ...) to stable short aliases (`device-1`, `device-2`, ...) for the lifetime of one recorder
/// instance. Only the alias is ever recorded (ADR-007 §禁止 — no full identifier/MAC in diagnostics,
/// a stable short alias instead).
///
/// The table is keyed on the raw string itself rather than on its hash. A hash key was smaller but
/// not injective: two different devices whose keys collided would be handed the same alias and would
/// read as one device in a trace, which is exactly the kind of silent wrong answer diagnostics exist
/// to rule out. `String.hashValue` is also seeded per process, so the key was never portable anyway.
///
/// The raw values this holds are memory-only and never leave the table: the alias is the only thing
/// returned, `DiagnosticsRecorder` keeps its instance private inside the actor, the type is not
/// `Codable`, and the descriptions below deliberately withhold the contents so that logging or
/// dumping a recorder cannot print them.
public struct DeviceAlias: Sendable {
    private var aliasesByRaw: [String: String] = [:]
    private var nextIndex: Int = 1

    public init() {}

    /// Returns the stable alias for `raw`, assigning a new one on first sight.
    public mutating func alias(for raw: String) -> String {
        if let existing = aliasesByRaw[raw] {
            return existing
        }
        let assigned = "device-\(nextIndex)"
        nextIndex += 1
        aliasesByRaw[raw] = assigned
        return assigned
    }

    /// How many distinct raw values have been seen. Safe to log — it counts, it does not name.
    public var assignedCount: Int { aliasesByRaw.count }
}

extension DeviceAlias: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DeviceAlias(assigned: \(assignedCount))" }
    public var debugDescription: String { description }
}
