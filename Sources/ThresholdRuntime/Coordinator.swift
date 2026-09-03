import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// The one place where sensing, system state and policy meet (architecture.md §5).
///
/// An actor, so the two Domain state machines it owns can be plain non-`Sendable` structs that
/// never escape and therefore cannot race (ADR-006). `handle(_:)` is deliberately **not** `async`:
/// with no suspension point inside it, one input is processed end to end before the next begins,
/// which is what makes the ledger and the deadline schedule reason about a single, settled state.
///
/// What it does not do is just as load-bearing: no RSSI maths, no CoreBluetooth, no IOKit, no
/// diagnostics formatting, no persistence (§5.2). Side effects are handed to a detached task and
/// their outcome returns as an ordinary input, so the actor never awaits a controller.
public actor Coordinator {

    /// Scanner restarts after an unexpected stream end, and the pause between them (§5.4).
    static let maxScannerRestarts = 3
    static let scannerRestartDelay = Duration.seconds(2)

    // MARK: - Boundaries

    let scanner: any BLEScanning
    let screenProvider: any ScreenStateProviding
    let sessionProvider: any SessionStateProviding
    let powerProvider: any PowerStateProviding
    let inputProvider: any InputActivityProviding
    let lockController: any LockControlling
    let wakeController: any WakeControlling
    let clock: any MonotonicClock

    // MARK: - Owned domain state

    var engine: ProximityEngine
    var policy: PolicyEngine
    /// Rebuilds the proximity engine when the trusted-device set changes: `ProximityEngine` fixes
    /// its device set at construction, and the composition root is the only thing that knows which
    /// configuration and fusion strategy the engine was built with.
    let makeEngine: @Sendable (Set<DeviceID>, CalibrationGate) -> ProximityEngine

    // MARK: - Cached system state (§5.1)

    var screen: ScreenState
    var session: SessionState
    var power: PowerState
    var settings: PolicySettings
    var gate: CalibrationGate
    var devices: Set<DeviceID>
    /// Replayed into a rebuilt engine so a device-set change does not silently drop the sensor axis
    /// back to `initializing` and stall every action until the scanner next reports.
    var lastSensorStatus: SensorStatus?
    /// The most recent policy deadline, kept so an input that only moves the engine's own deadline
    /// can reschedule without re-running policy.
    var lastPolicyDeadline: MonotonicInstant?

    // MARK: - Tasks and lifecycle

    var runTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
    /// Bumped on every deadline cancellation or reschedule, and again on `.systemWillSleep`. The
    /// sleeping deadline task captures this value before it suspends and, when it wakes, delivers
    /// its tick only if the epoch it captured is still current (§5.4, `deliverDeadlineTick`). This
    /// replaces a `Task.isCancelled` check that used to run *outside* actor isolation: that check
    /// and the actor hop that followed it left a window where `.systemWillSleep` could cancel the
    /// task just after the check passed, and the stale tick would still land and re-arm a timer
    /// while asleep. The check below runs *inside* actor isolation instead, serialized against
    /// every other mutation, so there is no such window.
    var deadlineEpoch: UInt64 = 0
    var isStopped = false
    /// Bumped whenever the proximity subsystem is rebuilt. Action ids and episode ids both restart
    /// from scratch at that point, so an outcome from before the rebuild could otherwise collide
    /// with a fresh entry; the epoch is what keeps `stale` decidable across a rebuild
    /// (security.md §2.6).
    var epoch: UInt64 = 0
    var dispatchEpoch: [ActionID: UInt64] = [:]
    /// The last `ProximitySnapshot` actually published on `events`, kept so a run of inputs that
    /// settles back to the same belief does not re-publish it (see `emitSnapshotUpdate`).
    var lastEmittedSnapshot: ProximitySnapshot?

    /// The Coordinator's outbound channel (architecture.md §5.1).
    ///
    /// `.unbounded`, deliberately: `actionDispatched`, `actionAcknowledged`, `transition`,
    /// `policyEvaluated` and `lifecycle` are an audit trail, and a bounded buffer that drops the
    /// oldest element under backpressure (`.bufferingNewest`) can silently drop one of these —
    /// exactly the kind of loss `DiagnosticsBridge` exists to prevent. A single flood-prone
    /// producer, `snapshotUpdated`, shares the same channel; rather than give it its own
    /// bounded stream, it is coalesced at the source instead (`emitSnapshotUpdate`), so an
    /// unbounded buffer here is bounded in practice by how often the engine's belief actually
    /// changes, not by how often an input arrives.
    public nonisolated let events: AsyncStream<CoordinatorEvent>
    private nonisolated let continuation: AsyncStream<CoordinatorEvent>.Continuation

    // MARK: - Init

    public init(
        scanner: any BLEScanning,
        screen: any ScreenStateProviding,
        session: any SessionStateProviding,
        power: any PowerStateProviding,
        input: any InputActivityProviding,
        lock: any LockControlling,
        wake: any WakeControlling,
        clock: any MonotonicClock,
        engine: ProximityEngine,
        policy: PolicyEngine,
        settings: PolicySettings,
        gate: CalibrationGate,
        devices: Set<DeviceID>,
        makeEngine: @escaping @Sendable (Set<DeviceID>, CalibrationGate) -> ProximityEngine = {
            ProximityEngine(devices: $0, gate: $1)
        }
    ) {
        self.scanner = scanner
        self.screenProvider = screen
        self.sessionProvider = session
        self.powerProvider = power
        self.inputProvider = input
        self.lockController = lock
        self.wakeController = wake
        self.clock = clock
        self.engine = engine
        self.policy = policy
        self.makeEngine = makeEngine
        self.settings = settings
        self.gate = gate
        self.devices = devices
        self.screen = screen.current
        self.session = session.current
        self.power = power.current

        let (stream, continuation) = AsyncStream<CoordinatorEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    // MARK: - Lifecycle

    /// Starts scanning and opens one child task per input stream. Idempotent.
    ///
    /// `startScanning` is skipped for an empty device set so a fresh install does not raise the
    /// Bluetooth permission prompt before the user has chosen anything (§5.4).
    public func start() {
        guard runTask == nil, !isStopped else { return }
        if !devices.isEmpty { scanner.startScanning(for: devices) }
        refreshSystemCaches()
        runTask = Task { [weak self] in await self?.runLoops() }
        evaluate(trigger: .settings)
    }

    /// Cancels the input and deadline tasks.
    ///
    /// In-flight controller tasks are deliberately *not* cancelled: a lock that has been issued is
    /// committed and should complete. Its outcome arrives after `isStopped` and is ignored (§5.4).
    public func stop() {
        isStopped = true
        runTask?.cancel()
        runTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.finish()
    }

    /// The system state cached at construction can be stale by the time `start()` runs, and
    /// `changes` only reports what happens next.
    private func refreshSystemCaches() {
        screen = screenProvider.current
        session = sessionProvider.current
        power = powerProvider.current
    }

    // MARK: - Read-only views

    /// The settled proximity state. The engine itself never leaves the actor, so this is how the UI
    /// and the tests ask what it currently believes.
    public var proximitySnapshot: ProximitySnapshot { engine.snapshot }

    /// The action ledger, in creation order. Read-only: entries are advanced only by `PolicyEngine`.
    public var actionLedger: [LedgerEntry] { policy.ledger }

    // MARK: - Single entry point (§5.3)

    public func handle(_ input: CoordinatorInput) {
        guard !isStopped else { return }
        switch input {
        case .observation(let observation):
            // A plain sample that changes nothing is not a policy trigger; it can still move the
            // engine's deadline, so the schedule is refreshed either way.
            apply(engine.handle(.observation(observation)), trigger: .presence, always: false)

        case .sensor(let status, let at):
            lastSensorStatus = status
            apply(engine.handle(.sensor(status, at: at)), trigger: .sensor, always: true)

        case .tick(let at):
            apply(engine.handle(.tick(at: at)), trigger: .deadline, always: true)

        case .screen(let state, _):
            screen = state
            evaluate(trigger: .screen)

        case .session(let state, _):
            session = state
            evaluate(trigger: .session)

        case .power(let state, _):
            power = state
            evaluate(trigger: .power)

        case .settingsChanged(let updated):
            settings = updated
            evaluate(trigger: .settings)

        case .calibrationChanged(let updated):
            gate = updated
            engine.update(gate: updated)
            emitSnapshotUpdate()
            evaluate(trigger: .calibration)

        case .devicesChanged(let updated):
            rebuildProximitySubsystem(devices: updated)

        case .actionOutcome(let id, let episode, let outcome):
            acknowledge(id, episode: episode, outcome: outcome)

        case .lifecycle(let event):
            handle(lifecycle: event)
        }
    }

    // MARK: - Input plumbing

    /// Emits the transitions, publishes the settled snapshot when it is newsworthy, then either
    /// re-runs policy or just re-arms the deadline. Every engine-facing input funnels through here
    /// so the snapshot a subscriber sees is always the one policy was evaluated against.
    ///
    /// A plain observation that moves nothing (`always: false`, no transitions) is by far the most
    /// common input — a silent run can produce thousands of them — and does not even attempt a
    /// `snapshotUpdated` publish: it neither transitioned nor triggered policy, so there is nothing
    /// newsworthy about it. Everything else (`always: true`, or a real transition) goes through
    /// `emitSnapshotUpdate`, which still only publishes when the snapshot actually differs from the
    /// last one published (MEDIUM-2).
    private func apply(_ transitions: [ProximityTransition], trigger: PolicyTrigger, always: Bool) {
        for transition in transitions { emit(.transition(transition)) }
        if always || !transitions.isEmpty {
            emitSnapshotUpdate()
            evaluate(trigger: trigger)
        } else {
            rescheduleDeadline(policyDeadline: lastPolicyDeadline)
        }
    }

    /// Publishes `snapshotUpdated` only when the engine's snapshot differs from the last one
    /// published (MEDIUM-2). `events` is unbounded, so this is not about avoiding drops — it is
    /// about not making every subscriber re-derive the same belief thousands of times over an
    /// otherwise uneventful run.
    private func emitSnapshotUpdate() {
        let current = engine.snapshot
        guard current != lastEmittedSnapshot else { return }
        lastEmittedSnapshot = current
        emit(.snapshotUpdated(current))
    }

    private func handle(lifecycle event: LifecycleEvent) {
        emit(.lifecycle(event))
        switch event {
        case .systemWillSleep:
            // No evaluation: the point of this branch is that nothing is scheduled or attempted
            // while the machine is asleep.
            power = .systemAsleep
            deadlineTask?.cancel()
            deadlineTask = nil
            deadlineEpoch &+= 1
            scanner.pause()

        case .systemDidWake:
            power = .awake
            scanner.resume()
            // Evidence gathered before the sleep is not evidence now; presence must be re-earned
            // from `minSamples + confirmDuration` (security.md §2.5).
            apply(engine.handle(.reset(.systemWake, at: clock.now())), trigger: .power, always: true)

        case .screensDidSleep:
            power = .displayAsleep
            evaluate(trigger: .power)

        case .screensDidWake:
            power = .awake
            evaluate(trigger: .power)
        }
    }

    /// A changed trusted-device set restarts the whole proximity subsystem.
    ///
    /// Both engines are rebuilt, not just the proximity one: `ProximityEngine` fixes its device set
    /// at construction and restarts its episode counter, so a surviving ledger could match an old
    /// entry against a new episode of the same number. Rebuilding the ledger too, behind a bumped
    /// `epoch`, keeps "stale" a decidable question.
    private func rebuildProximitySubsystem(devices updated: Set<DeviceID>) {
        devices = updated
        scanner.startScanning(for: updated)
        epoch &+= 1
        dispatchEpoch.removeAll()
        engine = makeEngine(updated, gate)
        policy = PolicyEngine()
        lastPolicyDeadline = nil

        let now = clock.now()
        var transitions: [ProximityTransition] = []
        if let lastSensorStatus {
            transitions += engine.handle(.sensor(lastSensorStatus, at: now))
        }
        transitions += engine.handle(.reset(.devicesChanged, at: now))
        apply(transitions, trigger: .presence, always: true)
    }

    nonisolated func emit(_ event: CoordinatorEvent) {
        continuation.yield(event)
    }
}
