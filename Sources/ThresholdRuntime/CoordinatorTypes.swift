import ThresholdDomain

/// System lifecycle notifications the Coordinator reacts to (architecture.md §5.4).
///
/// Deliberately four cases rather than a single "sleep" event: system sleep invalidates every
/// presence belief and must reset the engine, while a display going dark says nothing at all
/// about where the user is.
public enum LifecycleEvent: Sendable, Equatable, CustomStringConvertible {
    case systemWillSleep
    case systemDidWake
    case screensDidSleep
    case screensDidWake

    public var description: String {
        switch self {
        case .systemWillSleep: return "systemWillSleep"
        case .systemDidWake: return "systemDidWake"
        case .screensDidSleep: return "screensDidSleep"
        case .screensDidWake: return "screensDidWake"
        }
    }
}

/// Everything that can reach the Coordinator, from every boundary, as one closed set
/// (architecture.md §5.3).
///
/// There is no `inputActivity` case on purpose: no system signal announces the *start* of
/// idleness, so `InputActivityProviding.current` is polled at the moment a `PolicySnapshot` is
/// built rather than pushed (architecture.md §5.1).
public enum CoordinatorInput: Sendable, Equatable {
    case observation(BLEObservation)
    case sensor(SensorStatus, at: MonotonicInstant)
    /// Scheduled by the Coordinator's own deadline task, or sent by a test.
    case tick(MonotonicInstant)
    case screen(ScreenState, at: MonotonicInstant)
    case session(SessionState, at: MonotonicInstant)
    case power(PowerState, at: MonotonicInstant)
    case settingsChanged(PolicySettings)
    case calibrationChanged(CalibrationGate)
    /// The trusted-device set changed. Restarts scanning and the proximity subsystem (§5.4).
    case devicesChanged(Set<DeviceID>)
    /// A dispatched action finished. `episodeID` is what makes a superseded outcome recognisable.
    case actionOutcome(ActionID, EpisodeID, ActionOutcome)
    case lifecycle(LifecycleEvent)
}

/// One `PolicyEngine.evaluate` call, flattened into a value that can leave the actor.
///
/// `PolicyOutput` itself is not `Equatable` and carries no trigger or instant, both of which a
/// diagnostics reader needs to answer "why did it lock *then*".
public struct PolicyEvaluation: Sendable, Equatable {
    /// Diagnostic context only — it never participated in the decision (proximity-domain.md §6.2).
    public let trigger: PolicyTrigger
    public let at: MonotonicInstant
    public let action: PolicyAction?
    public let nextDeadline: MonotonicInstant?
    public let rationale: [PolicyRationale]

    public init(
        trigger: PolicyTrigger,
        at: MonotonicInstant,
        action: PolicyAction?,
        nextDeadline: MonotonicInstant?,
        rationale: [PolicyRationale]
    ) {
        self.trigger = trigger
        self.at = at
        self.action = action
        self.nextDeadline = nextDeadline
        self.rationale = rationale
    }
}

/// The Coordinator's only outbound channel (architecture.md §5.1).
///
/// Domain values, not diagnostics records: the Domain does not know `ThresholdDiagnostics` exists,
/// and `DiagnosticsBridge` is what turns these into `DiagnosticEvent`s (ADR-007).
public enum CoordinatorEvent: Sendable, Equatable {
    case snapshotUpdated(ProximitySnapshot)
    case transition(ProximityTransition)
    case policyEvaluated(PolicyEvaluation)
    case actionDispatched(PolicyAction)
    case actionAcknowledged(ActionID, EpisodeID, AcknowledgeResult)
    case lifecycle(LifecycleEvent)
    /// The observation stream ended unexpectedly and scanning was restarted. `attempt` counts from 1
    /// and never exceeds `Coordinator.maxScannerRestarts`.
    case sensorRestart(attempt: Int)
}
