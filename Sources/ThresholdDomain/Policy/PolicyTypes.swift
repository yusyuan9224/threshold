// System states are Policy inputs. `unknown` is deliberate: providers may not guess.
public enum ScreenState: Sendable, Equatable { case unlocked, locked, unknown }
public enum SessionState: Sendable, Equatable { case active, inactive, unknown }
public enum PowerState: Sendable, Equatable { case awake, displayAsleep, systemAsleep, unknown }

public enum ActionKind: Sendable, Equatable {
    case lock(LockReason)
    case wake
}

public enum LockReason: Sendable, Equatable {
    case userDeparted(PresenceEvidence)
    case evidenceExpired
}

public struct ActionID: Hashable, Sendable, Codable {
    public let raw: UInt64
    public init(_ raw: UInt64) { self.raw = raw }
}

public struct PolicyAction: Sendable, Equatable {
    public let id: ActionID
    public let kind: ActionKind
    public let episode: EpisodeID
    public let proposedAt: MonotonicInstant
    public init(id: ActionID, kind: ActionKind, episode: EpisodeID, proposedAt: MonotonicInstant) {
        self.id = id; self.kind = kind; self.episode = episode; self.proposedAt = proposedAt
    }
}

public enum ActionOutcome: Sendable, Equatable {
    case completed
    case failed(String)
}

public enum SilenceLockPolicy: Sendable, Equatable {
    case never
    case afterTimeout(Duration)
}

/// User-facing settings. Value type; changes flow into the Coordinator as an event.
public struct PolicySettings: Sendable, Equatable {
    public var autoLock: Bool = true
    public var wakeOnReturn: Bool = true
    /// Independent switch: may `departureThenSilent` evidence trigger a lock?
    public var lockOnDepartureThenSilent: Bool = true
    public var silenceLock: SilenceLockPolicy = .afterTimeout(.seconds(180))
    public var departedIdleGuard: Duration = .seconds(15)
    public var silenceIdleGuard: Duration = .seconds(60)
    public var wakeWindow: Duration = .seconds(30)
    public var retryAfter: Duration = .seconds(5)
    public var maxAttempts: Int = 3
    public init() {}
}

public enum PreconditionField: Sendable, Equatable { case sensor, session, power, screen, calibration }

public enum PreconditionResult: Sendable, Equatable {
    case satisfied
    case unsatisfied(PreconditionField)
    case indeterminate(PreconditionField)
}

/// Any `unknown` / unsatisfied field forbids the action (fail closed).
public struct RequiredPreconditions: Sendable, Equatable {
    public let sensor: SensorHealth
    public let session: SessionState
    public let power: PowerState
    public let screen: ScreenState
    public let calibration: CalibrationGate

    public init(sensor: SensorHealth, session: SessionState, power: PowerState, screen: ScreenState, calibration: CalibrationGate) {
        self.sensor = sensor; self.session = session; self.power = power; self.screen = screen; self.calibration = calibration
    }
}

/// Unknown supporting evidence is decided rule-by-rule, never globally.
public struct SupportingEvidence: Sendable, Equatable {
    public let inputIdle: Duration?
    public init(inputIdle: Duration?) { self.inputIdle = inputIdle }
}

public struct PolicySnapshot: Sendable {
    public let proximity: ProximitySnapshot
    public let preconditions: RequiredPreconditions
    public let evidence: SupportingEvidence
    public let settings: PolicySettings
    public let now: MonotonicInstant

    public init(proximity: ProximitySnapshot, preconditions: RequiredPreconditions, evidence: SupportingEvidence, settings: PolicySettings, now: MonotonicInstant) {
        self.proximity = proximity; self.preconditions = preconditions; self.evidence = evidence; self.settings = settings; self.now = now
    }
}

public enum PolicyTrigger: Sendable, Equatable {
    case presence, sensor, screen, session, power, input, settings, calibration, deadline, actionOutcome
}

public enum PolicyRationale: Sendable, Equatable {
    case preconditionIndeterminate(PreconditionField)
    case preconditionUnsatisfied(PreconditionField)
    case supportingEvidenceMissing
    case supportingEvidenceContradicts
    case userActive
    case insufficientEvidence
    case noAbsenceEvidence
    case waiting(until: MonotonicInstant)
    case disabledBySettings
    case alreadyIssued(ActionID)
    case retrying(ActionID, attempt: Int)
    case gaveUp(ActionID)
    case confirmed(ActionID)
    case staleOutcome(ActionID)
    case outsideWakeWindow
    case presenceUncertain
    case proposed(ActionID)
}

public struct PolicyOutput: Sendable {
    public let action: PolicyAction?
    public let nextDeadline: MonotonicInstant?
    public let rationale: [PolicyRationale]
    public init(action: PolicyAction?, nextDeadline: MonotonicInstant?, rationale: [PolicyRationale]) {
        self.action = action; self.nextDeadline = nextDeadline; self.rationale = rationale
    }
}

public enum AcknowledgeResult: Sendable, Equatable { case applied, stale }

/// Effect lifecycle (architecture.md §6).
public enum ActionStage: Sendable, Equatable { case proposed, issued, acknowledged, confirmed, failed, stale, gaveUp }
