/// Why a raw observation was refused entry to the signal pipeline (docs/specs/proximity-domain.md §1.1).
public enum RejectionReason: String, Codable, Sendable, Equatable {
    /// `rssi` outside the physically meaningful closed range [-120, 0] dBm.
    case rssiOutOfRange
    /// The device is not in the trusted registry. Untrusted radios never reach the pipeline.
    case unknownDevice
    /// Timestamp precedes the last accepted one by more than `maxSkew`.
    case outOfOrder
}

/// Outcome of validating one observation. The rejecting reason is a return value, never a thrown
/// error or a log line: the caller records it for diagnostics.
public enum ValidationResult: Sendable, Equatable {
    case accepted
    case rejected(RejectionReason)

    public var isAccepted: Bool { self == .accepted }

    /// Diagnostics signal: the boundary handed us time that moved backwards further than tolerated.
    /// The Domain cannot read a clock, so this is the only way a clock problem can be surfaced.
    public var clockAnomaly: Bool { self == .rejected(.outOfOrder) }
}

/// Pure gate in front of the signal pipeline. No state of its own: the caller supplies the last
/// accepted instant for the same device and the trusted-device set.
public enum ObservationValidator {
    /// Lowest physically meaningful RSSI, in dBm. Anything weaker is a driver artefact.
    public static let minimumRSSI = -120
    /// Highest physically meaningful RSSI, in dBm.
    public static let maximumRSSI = 0

    /// Rules are applied in the order given by §1.1, so the reported reason is stable
    /// when a sample violates more than one of them.
    public static func validate(
        _ observation: BLEObservation,
        lastAccepted: MonotonicInstant?,
        knownDevices: Set<DeviceID>,
        maxSkew: Duration
    ) -> ValidationResult {
        guard observation.rssi >= minimumRSSI, observation.rssi <= maximumRSSI else {
            return .rejected(.rssiOutOfRange)
        }
        guard knownDevices.contains(observation.device) else {
            return .rejected(.unknownDevice)
        }
        if let lastAccepted, observation.at < lastAccepted - maxSkew {
            return .rejected(.outOfOrder)
        }
        return .accepted
    }
}
