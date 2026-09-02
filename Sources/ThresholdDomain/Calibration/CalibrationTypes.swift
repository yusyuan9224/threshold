/// Per-device calibration output (docs/specs/proximity-domain.md §7.1).
public struct CalibrationProfile: Codable, Sendable, Equatable {
    public let nearBaseline: Double
    public let farBaseline: Double
    public let noise: Double
    public let midpoint: Double
    public let slope: Double

    public init(nearBaseline: Double, farBaseline: Double, noise: Double, midpoint: Double, slope: Double) {
        self.nearBaseline = nearBaseline
        self.farBaseline = farBaseline
        self.noise = noise
        self.midpoint = midpoint
        self.slope = slope
    }

    /// Display-only fallback while not armed. Never appears inside `CalibrationGate.armed`.
    public static let `default` = CalibrationProfile(nearBaseline: -55, farBaseline: -85, noise: 4, midpoint: -70, slope: 6)
}

/// Persistence unit. Deliberately contains no `MonotonicInstant`.
public struct CalibrationRecord: Codable, Sendable, Equatable {
    public let device: DeviceID
    public let macIdentity: String
    public let profile: CalibrationProfile
    public let osMajorVersion: Int
    public let appVersion: String
    /// Wall-clock, only for display and (if enabled) age-based revalidation.
    public let createdAtUnixSeconds: Int64

    public init(device: DeviceID, macIdentity: String, profile: CalibrationProfile, osMajorVersion: Int, appVersion: String, createdAtUnixSeconds: Int64) {
        self.device = device
        self.macIdentity = macIdentity
        self.profile = profile
        self.osMajorVersion = osMajorVersion
        self.appVersion = appVersion
        self.createdAtUnixSeconds = createdAtUnixSeconds
    }
}

public enum CalibrationPhase: String, Codable, Sendable { case near, far }

public enum CalibrationFailure: Sendable, Equatable {
    case insufficientSamples(phase: CalibrationPhase)
    case overlap
    case tooNoisy(phase: CalibrationPhase)
}

public enum NotArmedReason: Sendable, Equatable {
    case noProfile
    case deviceMismatch
    case macMismatch
    case needsRevalidation(osMajorChanged: Bool)
    case driftExceeded
    case invalid(CalibrationFailure)
}

/// Gate for automation. `notArmed` keeps the engine running for preview/diagnostics but blocks Policy actions.
public enum CalibrationGate: Sendable, Equatable {
    case armed(CalibrationProfile)
    case notArmed(NotArmedReason)

    public var profileForScoring: CalibrationProfile {
        switch self {
        case .armed(let p): return p
        case .notArmed: return .default
        }
    }
    public var isArmed: Bool { if case .armed = self { return true } else { return false } }
}
