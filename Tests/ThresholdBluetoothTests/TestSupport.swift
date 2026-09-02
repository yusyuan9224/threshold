import CoreBluetooth
import Dispatch
import Foundation
import ThresholdDomain
@testable import ThresholdBluetooth

// MARK: - Clock

/// Monotonic, deterministic and thread-safe: every `now()` advances by 1 ms, so a
/// timestamp doubles as a call ordinal. Tests use that to prove which samples the
/// lossy buffer kept.
final class StubClock: BLEClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: Int64 = 0

    func now() -> MonotonicInstant {
        lock.withLock {
            nanoseconds += 1_000_000
            return MonotonicInstant(nanoseconds: nanoseconds)
        }
    }
}

// MARK: - Fake central

/// Drives `CoreBluetoothScanner` without a radio.
///
/// Callbacks are delivered via `queue.async`, exactly as CoreBluetooth delivers them
/// on the queue handed to `CBCentralManager(delegate:queue:)`. That is what lets a
/// test fire callbacks from several threads at once and still land inside the
/// scanner's confinement — and what makes the scanner's `dispatchPrecondition`
/// meaningful rather than vacuous.
final class FakeCentral: CentralManaging, @unchecked Sendable {
    private let queue: DispatchQueue
    private weak var sink: CentralEventSink?
    private let lock = NSLock()

    private var currentState: CBManagerState = .unknown
    private var scanning = false
    private var scanCalls = 0
    private var stopScanCalls = 0
    private var lastServicesWereNil: Bool?
    private var lastAllowedDuplicates: Bool?

    init(queue: DispatchQueue, sink: CentralEventSink) {
        self.queue = queue
        self.sink = sink
    }

    // MARK: CentralManaging

    var state: CBManagerState { lock.withLock { currentState } }
    var isScanning: Bool { lock.withLock { scanning } }

    func scanForPeripherals(withServices services: [CBUUID]?, options: [String: Any]?) {
        let servicesWereNil = services == nil
        let allowedDuplicates = options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool
        lock.withLock {
            scanning = true
            scanCalls += 1
            lastServicesWereNil = servicesWereNil
            lastAllowedDuplicates = allowedDuplicates
        }
    }

    func stopScan() {
        lock.withLock {
            scanning = false
            stopScanCalls += 1
        }
    }

    // MARK: Observed by tests

    var scanCallCount: Int { lock.withLock { scanCalls } }
    var stopScanCallCount: Int { lock.withLock { stopScanCalls } }
    var lastScanServicesWereNil: Bool? { lock.withLock { lastServicesWereNil } }
    var lastScanAllowedDuplicates: Bool? { lock.withLock { lastAllowedDuplicates } }

    // MARK: Driving

    func simulateState(_ newState: CBManagerState) {
        lock.withLock { currentState = newState }
        let rawValue = newState.rawValue
        queue.async { [weak self] in
            guard let self, let state = CBManagerState(rawValue: rawValue) else { return }
            self.sink?.didUpdateState(state)
        }
    }

    func simulateDiscovery(identifier: UUID, name: String? = nil, rssi: Int) {
        queue.async { [weak self] in
            self?.sink?.didDiscover(identifier: identifier, name: name, rssi: rssi)
        }
    }
}

/// Lets a test reach the `FakeCentral` the scanner created lazily.
final class CentralBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FakeCentral?

    var central: FakeCentral? { lock.withLock { stored } }
    func set(_ central: FakeCentral) { lock.withLock { stored = central } }
}

// MARK: - Harness

/// A scanner wired to a `FakeCentral`, plus the queue the scanner is confined to —
/// which is what makes `flush()` a real barrier rather than a sleep.
final class ScannerHarness: @unchecked Sendable {
    let queue: DispatchQueue
    let clock: StubClock
    let scanner: CoreBluetoothScanner
    private let box: CentralBox

    init() {
        let queue = DispatchQueue(label: "test.threshold.bluetooth.scan")
        let clock = StubClock()
        let box = CentralBox()
        self.queue = queue
        self.clock = clock
        self.box = box
        self.scanner = CoreBluetoothScanner(clock: clock, scanQueue: queue) { queue, sink in
            let central = FakeCentral(queue: queue, sink: sink)
            box.set(central)
            return central
        }
    }

    /// The central, if the scanner has created one yet.
    var central: FakeCentral? { box.central }

    /// Blocks until every block enqueued on `scanQueue` so far has run. Serial FIFO
    /// makes this exact, so no test needs a sleep to observe scanner state.
    func flush() { queue.sync {} }

    /// Two barriers: `onTermination` handlers re-enqueue onto the same queue.
    func flushTwice() {
        flush()
        flush()
    }
}

// MARK: - Stream draining

private actor Accumulator<Element: Sendable> {
    private(set) var items: [Element] = []
    func append(_ element: Element) { items.append(element) }
    var count: Int { items.count }
}

/// Collects what a still-open stream currently holds.
///
/// The scanner's streams never finish on their own, so the collector is raced against
/// a settle window and then cancelled. `settle` only has to outlast delivery of
/// already-buffered elements, never a real timeout.
func drain<Element: Sendable>(
    _ stream: AsyncStream<Element>,
    limit: Int,
    settle: Duration = .milliseconds(200)
) async -> [Element] {
    let accumulator = Accumulator<Element>()
    let task = Task {
        for await element in stream {
            await accumulator.append(element)
            if await accumulator.count >= limit { break }
        }
    }
    try? await Task.sleep(for: settle)
    task.cancel()
    _ = await task.result
    return await accumulator.items
}

// MARK: - Device ids

let deviceAUUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let deviceBUUID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
let deviceA = DeviceID(deviceAUUID.uuidString)
let deviceB = DeviceID(deviceBUUID.uuidString)
