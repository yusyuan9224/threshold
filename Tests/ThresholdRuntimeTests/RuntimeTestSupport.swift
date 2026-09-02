import os
import Testing
import ThresholdBluetooth
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdRuntime

// L3 integration support (docs/specs/testing.md §1): FakeScanner, Fake providers, FakeClock and spy
// controllers, wired into a real `Coordinator`. Nothing here is a stub of the code under test —
// only the boundaries are faked.

/// Seconds → `MonotonicInstant`. Specs speak in seconds; the Domain speaks in nanoseconds.
func at(_ seconds: Double) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: Int64(seconds * 1_000_000_000))
}

/// Same calibration the Domain tests use: −45 dBm scores 0.95 (well above enter) and −95 dBm
/// scores 0.001 (well below exit), so no test result depends on where the uncertain band sits.
let testProfile = CalibrationProfile(nearBaseline: -50, farBaseline: -70, noise: 3, midpoint: -60, slope: 5)
let nearRSSI = -45
let farRSSI = -95

/// Deliberately UUID-shaped: `DiagnosticsExportAnonymityCheck` rejects an export containing a UUID,
/// so a diagnostics leak of this id fails the export test loudly rather than silently.
let deviceA = DeviceID("11111111-2222-3333-4444-555555555555")

// MARK: - Event collection

/// Drains `Coordinator.events` into a lock-protected array so a test can assert on it at any time.
final class EventCollector: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [CoordinatorEvent]())

    var events: [CoordinatorEvent] { storage.withLock { $0 } }

    func append(_ event: CoordinatorEvent) { storage.withLock { $0.append(event) } }

    var transitions: [ProximityTransition] {
        events.compactMap { if case .transition(let value) = $0 { return value } else { return nil } }
    }

    var evaluations: [PolicyEvaluation] {
        events.compactMap { if case .policyEvaluated(let value) = $0 { return value } else { return nil } }
    }

    var dispatched: [PolicyAction] {
        events.compactMap { if case .actionDispatched(let value) = $0 { return value } else { return nil } }
    }

    var acknowledgements: [(ActionID, EpisodeID, AcknowledgeResult)] {
        events.compactMap {
            if case .actionAcknowledged(let id, let episode, let result) = $0 { return (id, episode, result) }
            return nil
        }
    }

    var restartAttempts: [Int] {
        events.compactMap { if case .sensorRestart(let attempt) = $0 { return attempt } else { return nil } }
    }

    var lifecycleEvents: [LifecycleEvent] {
        events.compactMap { if case .lifecycle(let value) = $0 { return value } else { return nil } }
    }

    func rationaleContains(_ rationale: PolicyRationale) -> Bool {
        evaluations.contains { $0.rationale.contains(rationale) }
    }
}

// MARK: - Controllers

/// `LockControlling` spy that can be held mid-flight.
///
/// `SpyLockController` returns immediately, which cannot express the two races the Coordinator
/// exists to survive: an outcome arriving after the episode moved on (T-07) and an outcome arriving
/// after `stop()`. This one suspends inside `lock(reason:)` until `release()` is called.
final class GatedLockController: LockControlling, Sendable {
    private struct State: Sendable {
        var reasons: [LockReason] = []
        var isGated: Bool
        var waiters: [CheckedContinuation<Void, Never>] = []
        var failure: LockError?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(gated: Bool = false, failure: LockError? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(isGated: gated, failure: failure))
    }

    var reasons: [LockReason] { state.withLock { $0.reasons } }
    var lockCount: Int { state.withLock { $0.reasons.count } }
    /// Calls currently suspended inside `lock(reason:)`.
    var pendingCount: Int { state.withLock { $0.waiters.count } }

    func lock(reason: LockReason) async throws {
        let (shouldWait, failure) = state.withLock { state -> (Bool, LockError?) in
            state.reasons.append(reason)
            return (state.isGated, state.failure)
        }
        if shouldWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // `release()` can land between the two lock acquisitions; re-checking inside the
                // second one is what stops a continuation from being parked forever.
                let resumeNow = state.withLock { state -> Bool in
                    guard state.isGated else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let failure { throw failure }
    }

    func fail(with error: LockError = .notConfirmed) { state.withLock { $0.failure = error } }
    func stopFailing() { state.withLock { $0.failure = nil } }

    /// Lets every suspended call return, and stops gating subsequent ones.
    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isGated = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

// MARK: - Harness

/// A `Coordinator` with every boundary faked, plus the helpers a scenario is written in.
final class RuntimeHarness: Sendable {
    let scanner: FakeScanner
    let screen: FakeScreenStateProvider
    let session: FakeSessionStateProvider
    let power: FakePowerStateProvider
    let input: FakeInputActivityProvider
    let lock: GatedLockController
    let wake: SpyWakeController
    let clock: FakeClock
    let coordinator: Coordinator
    let collector: EventCollector
    private let collectorTask: Task<Void, Never>

    init(
        devices: [DeviceID] = [deviceA],
        gate: CalibrationGate = .armed(testProfile),
        settings: PolicySettings = PolicySettings(),
        screen: ScreenState = .unlocked,
        session: SessionState = .active,
        power: PowerState = .awake,
        inputIdle: Duration? = .seconds(300),
        gatedLock: Bool = false,
        configuration: EngineConfiguration = EngineConfiguration(),
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        let deviceSet = Set(devices)
        self.scanner = FakeScanner()
        self.screen = FakeScreenStateProvider(initial: screen)
        self.session = FakeSessionStateProvider(initial: session)
        self.power = FakePowerStateProvider(initial: power)
        self.input = FakeInputActivityProvider(idle: inputIdle)
        self.lock = GatedLockController(gated: gatedLock)
        self.wake = SpyWakeController()
        let clock = FakeClock(start: at(0))
        self.clock = clock

        let makeEngine: @Sendable (Set<DeviceID>, CalibrationGate) -> ProximityEngine = { devices, gate in
            ProximityEngine(configuration: configuration, fusion: AnyDeviceFusion(), devices: devices, gate: gate)
        }
        self.coordinator = Coordinator(
            scanner: self.scanner,
            screen: self.screen,
            session: self.session,
            power: self.power,
            input: self.input,
            lock: self.lock,
            wake: self.wake,
            clock: clock,
            engine: makeEngine(deviceSet, gate),
            policy: PolicyEngine(),
            settings: settings,
            gate: gate,
            devices: deviceSet,
            makeEngine: makeEngine
        )

        let collector = EventCollector()
        self.collector = collector
        let events = coordinator.events
        // One subscriber owns the stream, so the diagnostics bridge is fed from the same loop
        // rather than from a second iteration that would steal events from the collector.
        let bridge = diagnostics.map { DiagnosticsBridge(recorder: $0, clock: clock) }
        self.collectorTask = Task {
            for await event in events {
                collector.append(event)
                await bridge?.record(event)
            }
        }
    }

    deinit { collectorTask.cancel() }

    /// Starts the Coordinator and brings the sensor axis to `healthy`, which is where every
    /// scenario that is not about sensor failure begins.
    func start(sensorAvailableAt seconds: Double = 0) async {
        await coordinator.start()
        await coordinator.handle(.sensor(.available, at: at(seconds)))
    }

    // MARK: Driving

    /// Feeds one observation, keeping the fake clock in step with the instant it carries.
    ///
    /// Both clocks must move together: the engine reads time from the observation, while policy and
    /// the deadline scheduler read it from `clock`.
    func observe(_ rssi: Int, at seconds: Double, device: DeviceID = deviceA) async {
        clock.advance(to: at(seconds))
        await coordinator.handle(.observation(BLEObservation(device: device, at: at(seconds), rssi: rssi)))
    }

    /// One observation per second, inclusive of both ends.
    func drive(_ rssi: Int, from: Double, through: Double, device: DeviceID = deviceA) async {
        var seconds = from
        while seconds <= through + 1e-9 {
            await observe(rssi, at: seconds, device: device)
            seconds += 1
        }
    }

    /// A burst of observations at `step`-second spacing, for scenarios about sample *counts*
    /// rather than elapsed seconds.
    func flood(_ rssi: Int, from: Double, through: Double, step: Double, device: DeviceID = deviceA) async {
        var seconds = from
        while seconds <= through + 1e-9 {
            await observe(rssi, at: seconds, device: device)
            seconds += step
        }
    }

    func tick(_ seconds: Double) async {
        clock.advance(to: at(seconds))
        await coordinator.handle(.tick(at(seconds)))
    }

    func setScreen(_ state: ScreenState, at seconds: Double) async {
        await coordinator.handle(.screen(state, at: at(seconds)))
    }

    // MARK: Reading

    var snapshot: ProximitySnapshot {
        get async { await coordinator.proximitySnapshot }
    }

    var ledger: [LedgerEntry] {
        get async { await coordinator.actionLedger }
    }

    /// Reaches `present` at t = 6 s, then `away` with `measuredFar` evidence at t = 20 s — the
    /// canonical "user walked away" run, matching the Domain-level engine tests.
    func driveToAway() async {
        await drive(nearRSSI, from: 0, through: 6)
        await drive(farRSSI, from: 7, through: 20)
    }
}

// MARK: - Waiting

/// Polls `condition` until it holds or `timeout` elapses. Returns whether it held.
///
/// Wall-clock, deliberately: this waits for *task scheduling*, not for domain time, which the
/// `FakeClock` owns. Effects are dispatched on detached tasks, so there is no other way to observe
/// their completion without adding test-only hooks to the Coordinator.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Waits for `count` tasks to be suspended on the fake clock, so a test can advance it knowing the
/// sleeper it means to wake is already registered.
@discardableResult
func waitForSleepers(_ clock: FakeClock, atLeast count: Int = 1) async -> Bool {
    await waitUntil { clock.pendingSleepers >= count }
}

/// Lets already-runnable tasks drain. Enough for an assertion that something did *not* happen,
/// where there is no state change to poll for.
func settle(_ rounds: Int = 12) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
