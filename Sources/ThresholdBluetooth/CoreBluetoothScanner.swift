import CoreBluetooth
import Dispatch
import Foundation
import ThresholdDomain

/// CoreBluetooth → the three scanner channels (bluetooth.md §5, ADR-006 "Option A").
///
/// # Sendable invariant
///
/// This type is `@unchecked Sendable`, which under ADR-006 is a contract, not a
/// decoration. The contract is:
///
/// **All mutable state is read and written only on `scanQueue`, a serial queue.**
/// Queue-confined: `central`, `monitoredDevices`, `isPaused`, `isScanning`,
/// `discoverySession` (which holds the discovery continuation and doubles as the
/// "is discovering" flag) and `lastSensorStatus`.
///
/// Immutable and themselves `Sendable`: `observationContinuation`,
/// `sensorContinuation`, `clock`, `scanQueue`, `makeCentral`.
///
/// Enforcement:
/// 1. Every public method does nothing but `scanQueue.async { … }` before touching state.
/// 2. `scanQueue` is the queue handed to `CBCentralManager(delegate:queue:)`, so
///    delegate callbacks are already on it — no hop, and no second isolation domain.
///    (This is precisely why ADR-006 rejected wrapping the delegate in an actor: CB
///    already provides serial isolation, and an actor would add a hop without adding
///    a single invariant.)
/// 3. In DEBUG every queue-confined method opens with
///    `dispatchPrecondition(condition: .onQueue(scanQueue))`.
/// 4. T-19 drives concurrent public API calls against out-of-order `FakeCentral`
///    callbacks and asserts the sensor sequence stays legal.
public final class CoreBluetoothScanner: BLEScanning, CentralEventSink, @unchecked Sendable {

    /// Boxes a discovery continuation so termination can be matched by identity —
    /// `AsyncStream.Continuation` is not `Equatable`, so a late `onTermination` from
    /// a superseded session must not tear down the current one.
    private final class DiscoverySession: Sendable {
        let continuation: AsyncStream<DiscoveredDevice>.Continuation
        init(_ continuation: AsyncStream<DiscoveredDevice>.Continuation) {
            self.continuation = continuation
        }
    }

    static let observationBufferSize = 64
    static let discoveryBufferSize = 32

    // MARK: - Immutable

    public let observations: AsyncStream<BLEObservation>
    public let sensorStates: AsyncStream<Timestamped<SensorStatus>>

    private let observationContinuation: AsyncStream<BLEObservation>.Continuation
    private let sensorContinuation: AsyncStream<Timestamped<SensorStatus>>.Continuation
    private let clock: BLEClock
    private let scanQueue: DispatchQueue
    private let makeCentral: @Sendable (DispatchQueue, CentralEventSink) -> CentralManaging

    // MARK: - scanQueue-confined

    private var central: CentralManaging?
    private var monitoredDevices: Set<DeviceID> = []
    private var isPaused = false
    private var isScanning = false
    private var discoverySession: DiscoverySession?
    /// Last status yielded on `sensorStates`. Kept so a repeated `CBManagerState`
    /// (CoreBluetooth does redeliver) cannot produce two identical consecutive
    /// events, which would corrupt the diagnostics transition sequence.
    private var lastSensorStatus: SensorStatus?
    /// Set when `performPause()` reports `.degraded(.scanInterrupted)` because a scan
    /// or discovery was actually running. `performResume()` consults it to decide
    /// whether recovery is its call to make (architecture.md §5.4) — a pause that
    /// found nothing running must not make resume claim `.available` out of nowhere.
    private var scanWasInterruptedByPause = false

    /// Derived rather than stored, so it cannot drift out of sync with the session.
    private var isDiscovering: Bool { discoverySession != nil }

    // MARK: - Init

    public convenience init(clock: BLEClock) {
        self.init(
            clock: clock,
            scanQueue: DispatchQueue(label: "app.threshold.bluetooth.scan"),
            makeCentral: { queue, sink in CoreBluetoothCentral(queue: queue, sink: sink) }
        )
    }

    /// Designated initializer. `makeCentral` is the seam tests use to inject a fake,
    /// and it is a factory rather than an instance so that central creation stays
    /// lazy (architecture.md §5.4: creating a `CBCentralManager` is what raises the
    /// permission prompt, so it must not happen at launch).
    init(
        clock: BLEClock,
        scanQueue: DispatchQueue,
        makeCentral: @escaping @Sendable (DispatchQueue, CentralEventSink) -> CentralManaging
    ) {
        self.clock = clock
        self.scanQueue = scanQueue
        self.makeCentral = makeCentral

        let (observationStream, observationContinuation) = AsyncStream<BLEObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.observationBufferSize)
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
        // Reads `discoverySession` off `scanQueue`, which the type's Sendable
        // contract otherwise forbids — safe here by construction: every queue-confined
        // closure that could still be pending (`scanQueue.async { self.perform... }`,
        // `makeCentral`'s callbacks, `onTermination`) captures `self` strongly, so if
        // any of them had not yet run, this instance could not be deinitializing. By
        // the time `deinit` runs, no confined access to `discoverySession` can be in
        // flight, so there is nothing left to race.
        discoverySession?.continuation.finish()
    }

    // MARK: - State mapping (bluetooth.md §3)

    /// `nil` means "yield nothing and wait for the next state".
    static func sensorStatus(for state: CBManagerState) -> SensorStatus? {
        switch state {
        case .poweredOn: .available
        case .poweredOff: .unavailable(.poweredOff)
        case .unauthorized: .unavailable(.unauthorized)
        case .unsupported: .unavailable(.unsupported)
        case .resetting: .degraded(.resetting)
        case .unknown: nil
        // A state added by a future SDK is treated like `.unknown`: holding the last
        // known status is safer than inventing an availability claim the engine would
        // act on. `.unavailable(.scannerFailed)` is the Coordinator's call, not ours.
        @unknown default: nil
        }
    }

    // MARK: - BLEScanning

    public func startScanning(for devices: Set<DeviceID>) {
        scanQueue.async { self.performStartScanning(for: devices) }
    }

    public func pause() {
        scanQueue.async { self.performPause() }
    }

    public func resume() {
        scanQueue.async { self.performResume() }
    }

    public func stopScanning() {
        scanQueue.async { self.performStopScanning() }
    }

    public func discover() -> AsyncStream<DiscoveredDevice> {
        let (stream, continuation) = AsyncStream<DiscoveredDevice>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.discoveryBufferSize)
        )
        let session = DiscoverySession(continuation)
        // Set before the hop: a consumer that cancels immediately must still tear the
        // session down, and `onTermination` fires on whatever thread terminates it.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.scanQueue.async { self.performDiscoveryEnded(session) }
        }
        scanQueue.async { self.performStartDiscovery(session) }
        return stream
    }

    public func stopDiscovery() {
        scanQueue.async { self.performStopDiscovery() }
    }

    // MARK: - CentralEventSink (already on scanQueue)

    func didUpdateState(_ state: CBManagerState) {
        assertOnScanQueue()
        if let status = Self.sensorStatus(for: state) {
            yieldSensorStatus(status)
        }
        // A state change can make scanning newly possible (`.poweredOn` arriving after
        // `startScanning`) or newly impossible (`.poweredOff`). It also takes
        // precedence over pause/resume signalling below (bluetooth.md §3): a
        // `.poweredOff` that lands while paused is reported here regardless of the
        // pause/resume bookkeeping in `performPause`/`performResume`.
        syncScanState()
    }

    func didDiscover(identifier: UUID, name: String?, rssi: Int) {
        assertOnScanQueue()
        let device = DeviceID(identifier.uuidString)
        // Time is stamped here, at the boundary, from the injected clock
        // (architecture.md §4.2). Both channels share one instant for one packet.
        let at = clock.now()

        if isScanning, !isPaused, monitoredDevices.contains(device) {
            observationContinuation.yield(
                BLEObservation(device: device, at: at, rssi: rssi, source: .advertisement)
            )
        }

        if !isPaused, let session = discoverySession {
            session.continuation.yield(
                DiscoveredDevice(id: device, advertisedName: name, rssi: rssi, at: at)
            )
        }
    }

    // MARK: - scanQueue-confined implementation

    private func performStartScanning(for devices: Set<DeviceID>) {
        assertOnScanQueue()
        monitoredDevices = devices
        // Empty set means "do not scan" (bluetooth.md §2) — and must not create the
        // central, or an empty registry would still raise the permission prompt.
        isScanning = !devices.isEmpty
        if isScanning { ensureCentral() }
        syncScanState()
    }

    private func performPause() {
        assertOnScanQueue()
        guard !isPaused else { return }
        // Captured before flipping `isPaused`: this is "was a scan actually running",
        // not just caller intent, so a pause with nothing running (never started, or
        // powered off/resetting) reports nothing on the sensor channel.
        let wasActivelyScanning = (isScanning || isDiscovering) && central?.state == .poweredOn
        isPaused = true
        // `isScanning` is deliberately left alone: it is the caller's intent, and
        // `resume()` restores scanning only if we were scanning before the pause.
        if wasActivelyScanning {
            scanWasInterruptedByPause = true
            yieldSensorStatus(.degraded(.scanInterrupted))
        }
        syncScanState()
    }

    private func performResume() {
        assertOnScanQueue()
        guard isPaused else { return }
        isPaused = false
        // SPIKE-004: whether CoreBluetooth keeps delivering advertisements across a
        // sleep/wake cycle without a fresh `scanForPeripherals` is unverified. Until
        // the spike reports, resume always re-issues the scan explicitly; the stopScan
        // below is a no-op after a pause and only guards the case where CB believes it
        // is still scanning.
        if let central, central.isScanning { central.stopScan() }
        syncScanState()

        // Recovery is only ours to report if pause is what interrupted the scan, and
        // only once the central has actually reached `.poweredOn` again — a
        // `.poweredOff`/`.resetting` that arrived while paused already reported its
        // own status via `didUpdateState` and takes precedence (bluetooth.md §3).
        if scanWasInterruptedByPause {
            scanWasInterruptedByPause = false
            if central?.state == .poweredOn {
                yieldSensorStatus(.available)
            }
        }
    }

    /// Yields `status` on the sensor channel unless it repeats the last-yielded
    /// status. Shared by `didUpdateState` and the pause/resume signalling in
    /// `performPause`/`performResume` so "no consecutive duplicate sensor events"
    /// (T-19) holds regardless of which caller produced the status.
    private func yieldSensorStatus(_ status: SensorStatus) {
        assertOnScanQueue()
        guard status != lastSensorStatus else { return }
        lastSensorStatus = status
        sensorContinuation.yield(Timestamped(status, at: clock.now()))
    }

    private func performStopScanning() {
        assertOnScanQueue()
        isScanning = false
        // `monitoredDevices` is left intact: yields are gated on `isScanning`, and the
        // set is replaced wholesale by the next `startScanning(for:)`.
        syncScanState()
    }

    private func performStartDiscovery(_ session: DiscoverySession) {
        assertOnScanQueue()
        // One discovery session at a time: a second `discover()` supersedes the first.
        discoverySession?.continuation.finish()
        discoverySession = session
        ensureCentral()
        syncScanState()
    }

    private func performStopDiscovery() {
        assertOnScanQueue()
        guard let session = discoverySession else { return }
        discoverySession = nil
        session.continuation.finish()
        syncScanState()
    }

    private func performDiscoveryEnded(_ session: DiscoverySession) {
        assertOnScanQueue()
        // Identity check: a superseded or already-stopped session must not tear down
        // the session that replaced it.
        guard discoverySession === session else { return }
        discoverySession = nil
        syncScanState()
    }

    private func ensureCentral() {
        assertOnScanQueue()
        guard central == nil else { return }
        // Deferred to the first real need — creating the central is what triggers the
        // Bluetooth permission prompt (architecture.md §5.4).
        central = makeCentral(scanQueue, self)
    }

    /// The one place that starts or stops the radio scan, so the CB call cannot get
    /// out of step with the scanner's intent.
    private func syncScanState() {
        assertOnScanQueue()
        guard let central else { return }
        let shouldScan = (isScanning || isDiscovering) && !isPaused && central.state == .poweredOn

        if shouldScan {
            guard !central.isScanning else { return }
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else if central.isScanning {
            central.stopScan()
        }
    }

    private func assertOnScanQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(scanQueue))
        #endif
    }
}
