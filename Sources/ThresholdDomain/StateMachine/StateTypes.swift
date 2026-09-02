// Axis 1 — where do we believe the user is? Advanced only by *measured* signal.
public enum PresenceState: Sendable, Equatable {
    case unknown(UnknownReason)
    case present
    case departing
    case away
}

public enum UnknownReason: Sendable, Equatable {
    case initial
    case evidenceExpired
    case reset(ResetReason)
    case sensorRestored
}

public enum ResetReason: String, Codable, Sendable { case systemWake, bluetoothReset, sessionChanged, devicesChanged }

// Axis 2 — can we currently trust the sensing subsystem? Advanced only by adapter lifecycle events.
public enum SensorHealth: Sendable, Equatable {
    case initializing
    case healthy
    case degraded(DegradedReason)
    case unavailable(UnavailableReason)
}

/// Provenance of the current presence belief. Kept on the snapshot so Policy and diagnostics never lose it.
public enum PresenceEvidence: Sendable, Equatable {
    case none
    case measuredNear
    case measuredFar
    /// Stronger absence evidence than sudden silence — NOT confirmed physical absence.
    case departureThenSilent
}

public enum TransitionCause: Sendable, Equatable {
    // presence axis
    case confirmedNear, measuredFar, signalWeakened, signalRecovered, departureThenSilent, evidenceExpired
    case reset(ResetReason), sensorRestored
    // sensor axis
    case sensorBecameHealthy, sensorDegraded(DegradedReason), sensorUnavailable(UnavailableReason), sensorInitializing
    // device axis
    case deviceSilent, deviceReceiving
}

public enum Axis: Sendable, Equatable {
    case presence
    case sensor
    case device(DeviceID)
}

/// Increments on every presence transition. Actions carry it so stale outcomes can be recognised.
public struct EpisodeID: Hashable, Sendable, Codable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
    public func next() -> EpisodeID { EpisodeID(raw &+ 1) }
}

public struct ProximityTransition: Sendable, Equatable {
    public let axis: Axis
    public let from: String
    public let to: String
    public let at: MonotonicInstant
    public let cause: TransitionCause

    public init(axis: Axis, from: String, to: String, at: MonotonicInstant, cause: TransitionCause) {
        self.axis = axis; self.from = from; self.to = to; self.at = at; self.cause = cause
    }
}

public enum EngineInput: Sendable, Equatable {
    case observation(BLEObservation)
    case sensor(SensorStatus, at: MonotonicInstant)
    /// Sent by the scheduler at or after `nextDeadline`. Early ticks are harmless.
    case tick(at: MonotonicInstant)
    case reset(ResetReason, at: MonotonicInstant)
}

public struct ProximitySnapshot: Sendable, Equatable {
    public let presence: PresenceState
    public let presenceSince: MonotonicInstant
    public let episode: EpisodeID
    public let evidence: PresenceEvidence
    public let lastTransition: TransitionCause?
    public let sensor: SensorHealth
    public let devices: [DeviceID: DeviceTrack]
    public let nextDeadline: MonotonicInstant?

    public init(presence: PresenceState, presenceSince: MonotonicInstant, episode: EpisodeID, evidence: PresenceEvidence,
                lastTransition: TransitionCause?, sensor: SensorHealth, devices: [DeviceID: DeviceTrack], nextDeadline: MonotonicInstant?) {
        self.presence = presence; self.presenceSince = presenceSince; self.episode = episode; self.evidence = evidence
        self.lastTransition = lastTransition; self.sensor = sensor; self.devices = devices; self.nextDeadline = nextDeadline
    }
}

/// Initial Tunable Defaults — engineering values without field evidence (proximity-domain.md §4.3).
public struct EngineConfiguration: Sendable, Equatable {
    public var enterThreshold: Double = 0.7
    public var exitThreshold: Double = 0.3
    public var confirmDuration: Duration = .seconds(3)
    public var departureDelay: Duration = .seconds(10)
    public var silentThreshold: Duration = .seconds(10)
    public var evidenceTimeout: Duration = .seconds(30)
    public var minSamples: Int = 5
    public var departureSilentLookback: Int = 3
    public var unknownGrace: Duration = .seconds(30)
    // signal pipeline
    public var windowSize: Int = 7
    public var windowHorizon: Duration = .seconds(15)
    public var medianSpan: Int = 5
    public var emaAlpha: Double = 0.3
    public var maxSkew: Duration = .seconds(1)
    public var recencyFullUntil: Duration = .seconds(2)

    public init() {}
}
