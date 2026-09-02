import ThresholdDomain
import os

/// Hand-driven `BLEScanning` for Coordinator integration tests and UI development
/// (bluetooth.md §6). Lives in the main target, not the test target, because
/// `ThresholdRuntime`'s tests need it too.
///
/// Genuinely `Sendable` — not `@unchecked`: every stored property is either a `let`
/// of a `Sendable` type or lives inside one `OSAllocatedUnfairLock`. This mirrors the
/// System providers' isolation (architecture.md §4.1) and needs no invariant comment
/// because the compiler checks it.
public final class FakeScanner: BLEScanning, Sendable {

    /// Everything the fake records, in one lock so a snapshot is always coherent.
    private struct State: Sendable {
        var startCalls: [Set<DeviceID>] = []
        var monitoredDevices: Set<DeviceID> = []
        var pauseCount = 0
        var resumeCount = 0
        var stopScanningCount = 0
        var stopDiscoveryCount = 0
        var discoverCallCount = 0
        var isPaused = false
        var isScanning = false
        var discoveryContinuations: [AsyncStream<DiscoveredDevice>.Continuation] = []
    }

    public let observations: AsyncStream<BLEObservation>
    public let sensorStates: AsyncStream<Timestamped<SensorStatus>>

    private let observationContinuation: AsyncStream<BLEObservation>.Continuation
    private let sensorContinuation: AsyncStream<Timestamped<SensorStatus>>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {
        let (observationStream, observationContinuation) = AsyncStream<BLEObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(CoreBluetoothScanner.observationBufferSize)
        )
        self.observations = observationStream
        self.observationContinuation = observationContinuation

        let (sensorStream, sensorContinuation) = AsyncStream<Timestamped<SensorStatus>>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.sensorStates = sensorStream
        self.sensorContinuation = sensorContinuation
    }

    deinit {
        observationContinuation.finish()
        sensorContinuation.finish()
        for continuation in state.withLock({ $0.discoveryContinuations }) { continuation.finish() }
    }

    // MARK: - Recorded calls

    public var startCalls: [Set<DeviceID>] { state.withLock { $0.startCalls } }
    public var monitoredDevices: Set<DeviceID> { state.withLock { $0.monitoredDevices } }
    public var pauseCount: Int { state.withLock { $0.pauseCount } }
    public var resumeCount: Int { state.withLock { $0.resumeCount } }
    public var stopScanningCount: Int { state.withLock { $0.stopScanningCount } }
    public var stopDiscoveryCount: Int { state.withLock { $0.stopDiscoveryCount } }
    public var discoverCallCount: Int { state.withLock { $0.discoverCallCount } }
    public var isPaused: Bool { state.withLock { $0.isPaused } }
    public var isScanning: Bool { state.withLock { $0.isScanning } }

    // MARK: - Driving the fake

    public func emit(observation: BLEObservation) {
        observationContinuation.yield(observation)
    }

    public func emit(sensor status: SensorStatus, at instant: MonotonicInstant) {
        sensorContinuation.yield(Timestamped(status, at: instant))
    }

    /// Yields to every live discovery stream.
    public func emitDiscovery(_ device: DiscoveredDevice) {
        for continuation in state.withLock({ $0.discoveryContinuations }) {
            continuation.yield(device)
        }
    }

    /// Ends the observation and sensor channels, so a consumer's `for await` returns.
    public func finish() {
        observationContinuation.finish()
        sensorContinuation.finish()
        let continuations = state.withLock { state -> [AsyncStream<DiscoveredDevice>.Continuation] in
            defer { state.discoveryContinuations = [] }
            return state.discoveryContinuations
        }
        for continuation in continuations { continuation.finish() }
    }

    // MARK: - BLEScanning

    public func startScanning(for devices: Set<DeviceID>) {
        state.withLock {
            $0.startCalls.append(devices)
            $0.monitoredDevices = devices
            $0.isScanning = !devices.isEmpty
        }
    }

    public func pause() {
        state.withLock {
            $0.pauseCount += 1
            $0.isPaused = true
        }
    }

    public func resume() {
        state.withLock {
            $0.resumeCount += 1
            $0.isPaused = false
        }
    }

    public func stopScanning() {
        state.withLock {
            $0.stopScanningCount += 1
            $0.isScanning = false
        }
    }

    public func discover() -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream<DiscoveredDevice>.makeStream(
            bufferingPolicy: .bufferingNewest(CoreBluetoothScanner.discoveryBufferSize)
        )
        state.withLock {
            $0.discoverCallCount += 1
            $0.discoveryContinuations.append(continuation)
        }
        return stream
    }

    public func stopDiscovery() {
        let continuations = state.withLock { state -> [AsyncStream<DiscoveredDevice>.Continuation] in
            state.stopDiscoveryCount += 1
            defer { state.discoveryContinuations = [] }
            return state.discoveryContinuations
        }
        for continuation in continuations { continuation.finish() }
    }
}
