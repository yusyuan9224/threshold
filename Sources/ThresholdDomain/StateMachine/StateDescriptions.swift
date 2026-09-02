// Stable, human-readable labels for the three axes. These are what `ProximityTransition.from`
// and `.to` carry, so diagnostics can show a transition without pattern-matching every enum.
// They are diagnostic strings, not an encoding format: nothing parses them back.

extension PresenceState {
    public var label: String {
        switch self {
        case .unknown(let reason): return "unknown(\(reason.label))"
        case .present: return "present"
        case .departing: return "departing"
        case .away: return "away"
        }
    }
}

extension UnknownReason {
    public var label: String {
        switch self {
        case .initial: return "initial"
        case .evidenceExpired: return "evidenceExpired"
        case .reset(let reason): return "reset:\(reason.rawValue)"
        case .sensorRestored: return "sensorRestored"
        }
    }
}

extension SensorHealth {
    public var label: String {
        switch self {
        case .initializing: return "initializing"
        case .healthy: return "healthy"
        case .degraded(let reason): return "degraded(\(reason.rawValue))"
        case .unavailable(let reason): return "unavailable(\(reason.rawValue))"
        }
    }
}

extension DeviceObservationState {
    public var label: String {
        switch self {
        case .receiving: return "receiving"
        case .silent: return "silent"
        }
    }
}
