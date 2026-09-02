extension ProximityEngine {
    /// Sensor axis (§4.4). It never rewrites presence — a scanner failure is a fact about the
    /// scanner, not about the user (ADR-008). Its one effect on presence is row #11 when the
    /// subsystem *recovers*, because evidence gathered while it was untrustworthy is not evidence.
    mutating func applySensor(_ status: SensorStatus) -> [ProximityTransition] {
        switch status {
        case .available:
            return becomeHealthy()
        case .degraded(let reason):
            return leaveHealthy(for: .degraded(reason), cause: .sensorDegraded(reason))
        case .unavailable(let reason):
            return leaveHealthy(for: .unavailable(reason), cause: .sensorUnavailable(reason))
        }
    }

    private mutating func becomeHealthy() -> [ProximityTransition] {
        guard sensor != .healthy else { return [] }
        var emitted: [ProximityTransition] = []
        // Coming back from unavailable means the scanner restarts, which the spec models as a
        // visible pass through `initializing` rather than a silent jump.
        if case .unavailable = sensor {
            emitted.append(sensorTransition(to: .initializing, cause: .sensorInitializing))
        }
        emitted.append(sensorTransition(to: .healthy, cause: .sensorBecameHealthy))
        if sensorRestorePending {
            sensorRestorePending = false
            emitted += resetPresenceAxis(to: .unknown(.sensorRestored), cause: .sensorRestored)
        }
        return emitted
    }

    private mutating func leaveHealthy(for health: SensorHealth, cause: TransitionCause) -> [ProximityTransition] {
        guard sensor != health else { return [] }
        // Startup (`initializing → healthy`) is not a restore. Anything that reaches degraded or
        // unavailable is, so the next return to healthy re-earns presence from scratch.
        sensorRestorePending = true
        return [sensorTransition(to: health, cause: cause)]
    }

    private mutating func sensorTransition(to health: SensorHealth, cause: TransitionCause) -> ProximityTransition {
        let transition = ProximityTransition(
            axis: .sensor,
            from: sensor.label,
            to: health.label,
            at: now,
            cause: cause
        )
        sensor = health
        return transition
    }
}
