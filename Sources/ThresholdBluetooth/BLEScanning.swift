import ThresholdDomain

/// One device seen during an interactive discovery session (the "pick your device"
/// screen). Deliberately distinct from `BLEObservation`: discovery results carry an
/// advertised name and never enter the monitoring pipeline (bluetooth.md §2).
public struct DiscoveredDevice: Sendable, Equatable {
    public let id: DeviceID
    public let advertisedName: String?
    /// dBm, as reported by the advertisement.
    public let rssi: Int
    public let at: MonotonicInstant

    public init(id: DeviceID, advertisedName: String?, rssi: Int, at: MonotonicInstant) {
        self.id = id
        self.advertisedName = advertisedName
        self.rssi = rssi
        self.at = at
    }
}

/// The Bluetooth boundary, as three independent channels (bluetooth.md §2).
///
/// The channels differ in buffering because they differ in kind:
/// - `observations` is lossy — a newer RSSI sample supersedes an older one.
/// - `sensorStates` is state-bearing and must never be dropped by an observation
///   flood; diagnostics needs the full transition sequence (`resetting → poweredOn`
///   is the key evidence for SPIKE-004), and the event rate is a handful per day,
///   so unbounded carries no risk.
/// - discovery is a separate, short-lived stream per call.
public protocol BLEScanning: Sendable {
    /// Lossy. `.bufferingNewest(64)`.
    var observations: AsyncStream<BLEObservation> { get }

    /// State-bearing. `.unbounded`.
    var sensorStates: AsyncStream<Timestamped<SensorStatus>> { get }

    /// A fresh stream per call, `.bufferingNewest(32)`. Finishes on `stopDiscovery()`
    /// or when the consumer cancels. Never feeds the monitoring pipeline.
    func discover() -> AsyncStream<DiscoveredDevice>
    func stopDiscovery()

    /// Only these devices yield observations. An empty set means "do not scan".
    func startScanning(for devices: Set<DeviceID>)

    /// `systemWillSleep`.
    func pause()

    /// `systemDidWake`.
    func resume()

    func stopScanning()
}
