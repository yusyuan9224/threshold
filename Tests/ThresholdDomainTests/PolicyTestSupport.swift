import Testing
@testable import ThresholdDomain

/// Deterministic builders for Policy tests. Every field carries a "happy path" default
/// (away, awake, unlocked, armed), so each test states only the axis it exercises.
enum PolicyFixture {
    /// A calibrated profile deliberately distinct from `CalibrationProfile.default`,
    /// which the domain reserves for the display-only, not-armed fallback.
    static let profile = CalibrationProfile(nearBaseline: -54, farBaseline: -84, noise: 3, midpoint: -69, slope: 5)

    static func at(_ seconds: Double) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: Int64(seconds * 1_000_000_000))
    }

    static func proximity(
        presence: PresenceState = .away,
        presenceSince: MonotonicInstant = at(0),
        episode: EpisodeID = EpisodeID(1),
        evidence: PresenceEvidence = .measuredFar,
        lastTransition: TransitionCause? = nil,
        sensor: SensorHealth = .healthy,
        devices: [DeviceID: DeviceTrack] = [:],
        nextDeadline: MonotonicInstant? = nil
    ) -> ProximitySnapshot {
        ProximitySnapshot(
            presence: presence, presenceSince: presenceSince, episode: episode, evidence: evidence,
            lastTransition: lastTransition, sensor: sensor, devices: devices, nextDeadline: nextDeadline
        )
    }

    static func preconditions(
        sensor: SensorHealth = .healthy,
        session: SessionState = .active,
        power: PowerState = .awake,
        screen: ScreenState = .unlocked,
        calibration: CalibrationGate = .armed(profile)
    ) -> RequiredPreconditions {
        RequiredPreconditions(sensor: sensor, session: session, power: power, screen: screen, calibration: calibration)
    }

    /// `sensor` feeds both the proximity snapshot and the preconditions: in production both
    /// come from the engine's single sensor axis and must never disagree.
    static func snapshot(
        presence: PresenceState = .away,
        presenceSince: MonotonicInstant = at(0),
        episode: EpisodeID = EpisodeID(1),
        evidence: PresenceEvidence = .measuredFar,
        sensor: SensorHealth = .healthy,
        session: SessionState = .active,
        power: PowerState = .awake,
        screen: ScreenState = .unlocked,
        calibration: CalibrationGate = .armed(profile),
        inputIdle: Duration? = .seconds(300),
        settings: PolicySettings = PolicySettings(),
        now: MonotonicInstant = at(100)
    ) -> PolicySnapshot {
        PolicySnapshot(
            proximity: proximity(presence: presence, presenceSince: presenceSince, episode: episode,
                                 evidence: evidence, sensor: sensor),
            preconditions: preconditions(sensor: sensor, session: session, power: power,
                                         screen: screen, calibration: calibration),
            evidence: SupportingEvidence(inputIdle: inputIdle),
            settings: settings,
            now: now
        )
    }

    /// Canonical "user walked away from an awake, unlocked Mac" lock scenario.
    static func lockable(
        evidence: PresenceEvidence = .measuredFar,
        inputIdle: Duration? = .seconds(300),
        settings: PolicySettings = PolicySettings(),
        episode: EpisodeID = EpisodeID(1),
        screen: ScreenState = .unlocked,
        now: MonotonicInstant = at(100)
    ) -> PolicySnapshot {
        snapshot(presence: .away, episode: episode, evidence: evidence, screen: screen,
                 inputIdle: inputIdle, settings: settings, now: now)
    }

    /// Canonical "user returned to a display-asleep, locked Mac" wake scenario.
    static func wakeable(
        presenceSince: MonotonicInstant = at(100),
        settings: PolicySettings = PolicySettings(),
        episode: EpisodeID = EpisodeID(1),
        power: PowerState = .displayAsleep,
        screen: ScreenState = .locked,
        now: MonotonicInstant = at(100)
    ) -> PolicySnapshot {
        snapshot(presence: .present, presenceSince: presenceSince, episode: episode, evidence: .measuredNear,
                 power: power, screen: screen, inputIdle: nil, settings: settings, now: now)
    }
}

extension PolicyOutput {
    var lockReason: LockReason? {
        guard case .lock(let reason) = action?.kind else { return nil }
        return reason
    }

    var isWake: Bool { action?.kind == .wake }
}
