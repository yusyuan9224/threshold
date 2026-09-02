/// The three-axis proximity state machine (docs/specs/proximity-domain.md §4).
///
/// Entirely input-driven: time only ever arrives inside an `EngineInput`, and the engine reports
/// `nextDeadline` so the layer that *does* own a clock knows when to send the next tick (ADR-003).
/// Not `Sendable` by design — it is a value owned exclusively by the Coordinator actor.
///
/// Two rules shape everything below:
/// - Absence of evidence is not evidence of absence (ADR-008). Silence expires evidence; it never
///   produces `away` on its own.
/// - Only *measured* evaluations may weaken presence. Recency decay lowers the fused score as a
///   device goes quiet, so a threshold crossing seen at a tick is not measurement — it is the
///   absence of it. Rows #1–#5 and #9 therefore fire only on an accepted observation; the silence
///   rows #6–#8 and #10 fire on ticks.
public struct ProximityEngine {
    let configuration: EngineConfiguration
    let fusion: any PresenceFusion
    let scorer: PresenceScorer
    var gate: CalibrationGate

    /// Sorted so every derived value is order-independent and reproducible.
    let deviceIDs: [DeviceID]
    let deviceSet: Set<DeviceID>

    var pipelines: [DeviceID: SignalPipeline]
    /// Reorder reference for `ObservationValidator`: the newest accepted instant for this device,
    /// which does not move backwards when a reorder inside `maxSkew` is accepted (§1.1 note). Nil
    /// until the device is first heard, and again after a reset, so the first sample of a new
    /// episode is never judged against a timestamp from the old one.
    var lastAccepted: [DeviceID: MonotonicInstant] = [:]
    /// Silence reference: the same newest accepted instant, but falling back to the epoch or reset
    /// instant for a device never heard from, so a device that never speaks still goes silent.
    /// Silence and evidence expiry are both measured from here.
    var anchors: [DeviceID: MonotonicInstant] = [:]
    var observationStates: [DeviceID: DeviceObservationState] = [:]
    var tracks: [DeviceID: DeviceTrack] = [:]

    // Presence axis
    var presence: PresenceState = .unknown(.initial)
    var presenceSince: MonotonicInstant = .zero
    var episode = EpisodeID(0)
    var evidence: PresenceEvidence = .none
    var lastTransition: TransitionCause?
    var presenceUncertain = false
    /// Instant the fused score first reached `enterThreshold` in an unbroken run, and likewise
    /// for measured values below `exitThreshold`. Cleared on every presence transition.
    var enterSince: MonotonicInstant?
    var exitSince: MonotonicInstant?
    /// Last `departureSilentLookback` fused values seen at accepted observations. Survives presence
    /// transitions on purpose: row #6 asks about the values before silence, not since departing.
    var measuredHistory: [Double] = []
    var fusedScore: Double?

    // Sensor axis
    var sensor: SensorHealth = .initializing
    /// Set when the sensor leaves `healthy`, so returning to healthy is recognisable as a *restore*
    /// (which resets presence) rather than ordinary startup (which does not).
    var sensorRestorePending = false

    // Time, as carried by inputs only.
    var started = false
    var now: MonotonicInstant = .zero
    var deadline: MonotonicInstant?

    public init(
        configuration: EngineConfiguration = EngineConfiguration(),
        fusion: any PresenceFusion = AnyDeviceFusion(),
        devices: Set<DeviceID>,
        gate: CalibrationGate
    ) {
        self.configuration = configuration
        self.fusion = fusion
        self.scorer = PresenceScorer(configuration: configuration)
        self.gate = gate
        self.deviceSet = devices
        self.deviceIDs = devices.sorted { $0.raw < $1.raw }
        var pipelines: [DeviceID: SignalPipeline] = [:]
        for device in deviceIDs {
            pipelines[device] = SignalPipeline(configuration: configuration)
            observationStates[device] = .receiving
            anchors[device] = .zero
        }
        self.pipelines = pipelines
        rebuildTracks(at: .zero)
    }

    public var snapshot: ProximitySnapshot {
        ProximitySnapshot(
            presence: presence,
            presenceSince: presenceSince,
            episode: episode,
            evidence: evidence,
            lastTransition: lastTransition,
            sensor: sensor,
            devices: tracks,
            nextDeadline: deadline,
            presenceUncertain: presenceUncertain,
            fusedScore: fusedScore
        )
    }

    /// Calibration changed under us. Re-scores the tracks against the new profile but leaves the
    /// presence axis alone: a better yardstick is not evidence that the user moved (§4.2).
    public mutating func update(gate: CalibrationGate) {
        self.gate = gate
        rebuildTracks(at: now)
        fusedScore = fusion.fuse(orderedTracks)
    }

    public mutating func handle(_ input: EngineInput) -> [ProximityTransition] {
        switch input {
        case .observation(let observation): return handle(observation)
        case .sensor(let status, let at): return handle(status, at: at)
        case .tick(let at): return handleTick(at: at)
        case .reset(let reason, let at): return handleReset(reason, at: at)
        }
    }

    // MARK: - Inputs

    private mutating func handle(_ observation: BLEObservation) -> [ProximityTransition] {
        start(at: observation.at)
        let result = ObservationValidator.validate(
            observation,
            lastAccepted: lastAccepted[observation.device],
            knownDevices: deviceSet,
            maxSkew: configuration.maxSkew
        )
        advance(to: observation.at)
        if result.isAccepted {
            // A reorder inside `maxSkew` is accepted but must not rewind the device's last-seen
            // instant, which is what silence and recency are measured against.
            let effective = max(observation.at, anchors[observation.device] ?? observation.at)
            pipelines[observation.device]?.ingest(rssi: observation.rssi, at: effective)
            lastAccepted[observation.device] = effective
            anchors[observation.device] = effective
        }
        return settle(measured: result.isAccepted)
    }

    private mutating func handleTick(at instant: MonotonicInstant) -> [ProximityTransition] {
        // A tick from before the last input carries no new information; the engine has already
        // seen that instant pass.
        if started, instant < now { return [] }
        start(at: instant)
        advance(to: instant)
        return settle(measured: false)
    }

    private mutating func handle(_ status: SensorStatus, at instant: MonotonicInstant) -> [ProximityTransition] {
        start(at: instant)
        advance(to: instant)
        var emitted = applySensor(status)
        emitted += settle(measured: false)
        return emitted
    }

    private mutating func handleReset(_ reason: ResetReason, at instant: MonotonicInstant) -> [ProximityTransition] {
        start(at: instant)
        advance(to: instant)
        var emitted = resetPresenceAxis(to: .unknown(.reset(reason)), cause: .reset(reason))
        emitted += settle(measured: false)
        return emitted
    }

    // MARK: - Shared tail

    /// Device axis, then tracks, then presence axis, then the next deadline. Every input path
    /// ends here so the snapshot is always internally consistent.
    private mutating func settle(measured: Bool) -> [ProximityTransition] {
        var emitted = refreshDeviceAxis()
        rebuildTracks(at: now)
        emitted += evaluatePresence(measured: measured)
        updateDeadline()
        return emitted
    }

    /// The engine has no notion of "now" until the first input tells it one. Anchoring the device
    /// silence clocks to that instant is what makes a freshly built engine behave like a freshly
    /// reset one.
    private mutating func start(at instant: MonotonicInstant) {
        guard !started else { return }
        started = true
        now = instant
        presenceSince = instant
        for device in deviceIDs { anchors[device] = instant }
    }

    private mutating func advance(to instant: MonotonicInstant) {
        if instant > now { now = instant }
    }

    // MARK: - Device axis (§3.2)

    private mutating func refreshDeviceAxis() -> [ProximityTransition] {
        var emitted: [ProximityTransition] = []
        for device in deviceIDs {
            let anchor = anchors[device] ?? now
            let isSilent = (now - anchor) >= configuration.silentThreshold
            let current = observationStates[device] ?? .receiving
            switch (current, isSilent) {
            case (.receiving, true):
                observationStates[device] = .silent(since: anchor)
                emitted.append(deviceTransition(device, from: current, to: .silent(since: anchor), cause: .deviceSilent))
            case (.silent, false):
                observationStates[device] = .receiving
                emitted.append(deviceTransition(device, from: current, to: .receiving, cause: .deviceReceiving))
            default:
                break
            }
        }
        return emitted
    }

    private func deviceTransition(
        _ device: DeviceID,
        from: DeviceObservationState,
        to: DeviceObservationState,
        cause: TransitionCause
    ) -> ProximityTransition {
        ProximityTransition(axis: .device(device), from: from.label, to: to.label, at: now, cause: cause)
    }

    mutating func rebuildTracks(at instant: MonotonicInstant) {
        let profile = gate.profileForScoring
        var built: [DeviceID: DeviceTrack] = [:]
        for device in deviceIDs {
            let state = observationStates[device] ?? .receiving
            let estimate = pipelines[device]?.estimate
            var score: PresenceScore?
            // A silent device keeps its last estimate for display but contributes no score,
            // so it can never be fused into a presence decision.
            if state == .receiving, let estimate {
                score = scorer.score(for: estimate, now: instant, profile: profile)
            }
            built[device] = DeviceTrack(
                device: device,
                observation: state,
                estimate: estimate,
                score: score,
                isCalibrated: gate.isArmed
            )
        }
        tracks = built
    }

    var orderedTracks: [DeviceTrack] { deviceIDs.compactMap { tracks[$0] } }
}
