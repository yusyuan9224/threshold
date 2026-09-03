import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem

/// Turns `CoordinatorEvent`s into `DiagnosticEvent`s (ADR-007).
///
/// This is the seam that keeps the Domain ignorant of diagnostics: the Domain returns transitions,
/// decisions and rationale as values, the Coordinator publishes them, and only here does anything
/// know that a recorder exists. Nothing calls into the Domain from this direction.
///
/// Two privacy rules are honoured by construction rather than by review:
/// - A raw `DeviceID` is written only under a field key `PrivacyFilter` recognises as
///   device-identifying, so the recorder replaces it with a stable alias. It never appears in a
///   message, where it would have to survive a regex instead.
/// - No wall-clock time is read here. `DiagnosticsRecorder` attaches it at ingestion; this bridge
///   passes on the monotonic instant the event already carries.
public struct DiagnosticsBridge: Sendable {
    private let recorder: DiagnosticsRecorder
    private let clock: any MonotonicClock

    public init(recorder: DiagnosticsRecorder, clock: any MonotonicClock) {
        self.recorder = recorder
        self.clock = clock
    }

    /// Drains `events` until the Coordinator finishes the stream or the task is cancelled.
    public func run(_ events: AsyncStream<CoordinatorEvent>) async {
        for await event in events {
            await record(event)
        }
    }

    public func record(_ event: CoordinatorEvent) async {
        switch event {
        case .transition(let transition):
            await recordTransition(transition)
        case .snapshotUpdated(let snapshot):
            await recordSnapshot(snapshot)
        case .policyEvaluated(let evaluation):
            await recordEvaluation(evaluation)
        case .actionDispatched(let action):
            await recordDispatch(action)
        case .actionAcknowledged(let id, let episode, let result):
            await recordAcknowledgement(id, episode: episode, result: result)
        case .lifecycle(let lifecycle):
            await recorder.record(
                category: .systemLifecycle,
                message: lifecycle.description,
                monotonicNanoseconds: clock.now().nanoseconds
            )
        case .sensorRestart(let attempt):
            await recorder.record(
                category: .bluetoothLifecycle,
                message: "scanner restart",
                monotonicNanoseconds: clock.now().nanoseconds,
                fields: ["attempt": .int(Int64(attempt))]
            )
        }
    }

    // MARK: - Mapping

    private func recordTransition(_ transition: ProximityTransition) async {
        var fields: [String: DiagnosticEvent.FieldValue] = [
            "axis": .string(axisLabel(transition.axis)),
            "from": .string(transition.from),
            "to": .string(transition.to),
            "cause": .string(String(describing: transition.cause)),
        ]
        // Aliased by the recorder, never stored raw.
        if case .device(let id) = transition.axis {
            fields["device"] = .string(id.raw)
        }
        await recorder.record(
            category: .transition,
            message: "\(axisLabel(transition.axis)): \(transition.from) -> \(transition.to)",
            monotonicNanoseconds: transition.at.nanoseconds,
            fields: fields
        )
    }

    private func recordSnapshot(_ snapshot: ProximitySnapshot) async {
        var fields: [String: DiagnosticEvent.FieldValue] = [
            "presence": .string(snapshot.presence.label),
            "sensor": .string(snapshot.sensor.label),
            "evidence": .string(String(describing: snapshot.evidence)),
            "episodeID": .int(Int64(bitPattern: snapshot.episode.raw)),
            "presenceUncertain": .bool(snapshot.presenceUncertain),
        ]
        if let fused = snapshot.fusedScore { fields["fusedScore"] = .double(fused) }
        await recorder.record(
            category: .presenceScore,
            message: "presence \(snapshot.presence.label), sensor \(snapshot.sensor.label)",
            monotonicNanoseconds: snapshot.presenceSince.nanoseconds,
            fields: fields
        )
    }

    private func recordEvaluation(_ evaluation: PolicyEvaluation) async {
        var fields: [String: DiagnosticEvent.FieldValue] = [
            "trigger": .string(String(describing: evaluation.trigger)),
            "rationale": .string(evaluation.rationale.map { String(describing: $0) }.joined(separator: ",")),
            "actionProposed": .bool(evaluation.action != nil),
        ]
        if let deadline = evaluation.nextDeadline {
            fields["nextDeadlineNanoseconds"] = .int(deadline.nanoseconds)
        }
        await recorder.record(
            category: .policyEvaluation,
            message: "policy evaluated on \(evaluation.trigger)",
            monotonicNanoseconds: evaluation.at.nanoseconds,
            fields: fields
        )
    }

    private func recordDispatch(_ action: PolicyAction) async {
        await recorder.record(
            category: .actionDispatched,
            message: "dispatched \(String(describing: action.kind))",
            monotonicNanoseconds: action.proposedAt.nanoseconds,
            fields: [
                "actionID": .int(Int64(bitPattern: action.id.raw)),
                "episodeID": .int(Int64(bitPattern: action.episode.raw)),
                "kind": .string(String(describing: action.kind)),
            ]
        )
    }

    private func recordAcknowledgement(
        _ id: ActionID,
        episode: EpisodeID,
        result: AcknowledgeResult
    ) async {
        await recorder.record(
            category: .actionOutcome,
            message: "outcome \(String(describing: result))",
            monotonicNanoseconds: clock.now().nanoseconds,
            fields: [
                "actionID": .int(Int64(bitPattern: id.raw)),
                "episodeID": .int(Int64(bitPattern: episode.raw)),
                "result": .string(String(describing: result)),
            ]
        )
    }

    /// The device axis is labelled without its id: the identifier belongs in the aliased field.
    private func axisLabel(_ axis: Axis) -> String {
        switch axis {
        case .presence: return "presence"
        case .sensor: return "sensor"
        case .device: return "device"
        }
    }
}
