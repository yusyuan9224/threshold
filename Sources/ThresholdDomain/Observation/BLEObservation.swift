/// One received signal sample from one trusted device. Lossy by nature: newer samples supersede older ones.
public struct BLEObservation: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case advertisement, connectionRead }

    public let device: DeviceID
    public let at: MonotonicInstant
    /// dBm. Valid range enforced by `ObservationValidator`, not here.
    public let rssi: Int
    public let source: Source

    public init(device: DeviceID, at: MonotonicInstant, rssi: Int, source: Source = .advertisement) {
        self.device = device
        self.at = at
        self.rssi = rssi
        self.source = source
    }
}

/// A value paired with the monotonic instant at which it was produced at the boundary.
public struct Timestamped<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let at: MonotonicInstant
    public init(_ value: Value, at: MonotonicInstant) { self.value = value; self.at = at }
}
