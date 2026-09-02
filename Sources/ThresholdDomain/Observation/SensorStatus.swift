/// Status of the sensing subsystem itself, independent of any device.
/// Produced by the Bluetooth adapter; consumed by the engine's `SensorHealth` axis.
public enum SensorStatus: Codable, Sendable, Equatable {
    case available
    case degraded(DegradedReason)
    case unavailable(UnavailableReason)
}

public enum DegradedReason: String, Codable, Sendable { case resetting, scanInterrupted }
public enum UnavailableReason: String, Codable, Sendable { case poweredOff, unauthorized, unsupported, scannerFailed }
