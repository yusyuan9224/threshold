/// Maps raw device identifiers (MAC-like addresses, CoreBluetooth peripheral identifiers, ...) to
/// stable short aliases (`device-1`, `device-2`, ...) for the lifetime of one recorder instance.
///
/// The raw identifier itself is never stored: only a hash of it is kept as the lookup key, so the
/// same raw value always maps back to the same alias without retaining the value that produced it
/// (ADR-007 §禁止 — no full identifier/MAC in diagnostics, a stable short alias instead).
public struct DeviceAlias: Sendable {
    private var aliasesByHash: [Int: String] = [:]
    private var nextIndex: Int = 1

    public init() {}

    /// Returns the stable alias for `raw`, assigning a new one on first sight.
    public mutating func alias(for raw: String) -> String {
        let key = raw.hashValue
        if let existing = aliasesByHash[key] {
            return existing
        }
        let assigned = "device-\(nextIndex)"
        nextIndex += 1
        aliasesByHash[key] = assigned
        return assigned
    }
}
