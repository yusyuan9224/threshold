import CoreBluetooth
import Dispatch
import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdBluetooth

@Suite struct ScannerChannelIsolationTests {

    /// T-18 — an observation flood must not cost a single sensor event.
    ///
    /// This is the whole reason the two channels have different buffering policies
    /// (bluetooth.md §2): `observations` is lossy `.bufferingNewest(64)`, while
    /// `sensorStates` is `.unbounded` because a dropped `poweredOff` would leave the
    /// engine believing the radio is healthy.
    @Test func observationFloodDoesNotDropSensorEvents() async {
        let harness = ScannerHarness()
        let floodSize = 10_000

        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)

        // Nobody is consuming `observations` yet, so the flood fills the lossy buffer.
        for index in 0..<floodSize {
            harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -100 + (index % 50))
            // Sensor transitions land in the middle of the flood, interleaved with it.
            if index == floodSize / 3 { harness.central?.simulateState(.resetting) }
            if index == floodSize / 2 { harness.central?.simulateState(.poweredOn) }
            if index == (2 * floodSize) / 3 { harness.central?.simulateState(.poweredOff) }
        }
        harness.flush()

        // Not one sensor event lost, and the order is preserved.
        let statuses = await drain(harness.scanner.sensorStates, limit: 32).map(\.value)
        #expect(statuses == [
            .available,
            .degraded(.resetting),
            .available,
            .unavailable(.poweredOff),
        ])

        // The observation channel shed the backlog rather than growing without bound.
        let observations = await drain(harness.scanner.observations, limit: floodSize)
        #expect(observations.count <= CoreBluetoothScanner.observationBufferSize)
        #expect(!observations.isEmpty)

        // And it kept the *newest* samples: the stub clock advances 1 ms per stamp,
        // so surviving observations must sit at the tail of the flood.
        let timestamps = observations.map(\.at.nanoseconds)
        #expect(timestamps == timestamps.sorted())
        let tailBoundary = Int64(floodSize - CoreBluetoothScanner.observationBufferSize * 2) * 1_000_000
        #expect(timestamps.first ?? 0 > tailBoundary)
    }
}

@Suite struct ScannerConcurrencyTests {

    /// Deterministic pseudo-randomness, so a failure is reproducible.
    private struct Generator {
        private var seed: UInt64
        init(seed: UInt64) { self.seed = seed }
        mutating func next(_ upperBound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(upperBound))
        }
    }

    /// T-19 — hammer every public entry point from many threads while the fake central
    /// fires callbacks out of order, then assert the sensor channel is still legal.
    ///
    /// Two things are under test at once:
    /// 1. The `@unchecked Sendable` invariant. Every queue-confined method opens with
    ///    `dispatchPrecondition(condition: .onQueue(scanQueue))`, which traps in DEBUG
    ///    if any state is touched off-queue — so this test passing under a debug build
    ///    *is* the enforcement check.
    /// 2. The sensor sequence stays a legal state sequence: only mapped statuses, and
    ///    never two identical consecutive events (which would corrupt the diagnostics
    ///    transition record).
    @Test func concurrentAPICallsAndOutOfOrderCallbacksKeepTheSensorSequenceLegal() async {
        let harness = ScannerHarness()
        // Force the central to exist before the storm, so every worker sees one.
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        guard let central = harness.central else {
            Issue.record("central was not created")
            return
        }

        let states: [CBManagerState] = [.poweredOn, .poweredOff, .resetting, .unauthorized, .unsupported, .unknown]
        let scanner = harness.scanner

        DispatchQueue.concurrentPerform(iterations: 128) { iteration in
            var generator = Generator(seed: UInt64(iteration) &+ 1)

            for step in 0..<12 {
                switch generator.next(8) {
                case 0: scanner.startScanning(for: [deviceA])
                case 1: scanner.startScanning(for: [deviceA, deviceB])
                case 2: scanner.pause()
                case 3: scanner.resume()
                case 4: scanner.stopScanning()
                case 5: _ = scanner.discover()
                case 6: scanner.stopDiscovery()
                default: break
                }

                // Callbacks race the API calls, and arrive in whatever order the
                // queue happens to serialise them into.
                central.simulateState(states[generator.next(states.count)])
                central.simulateDiscovery(
                    identifier: step.isMultiple(of: 2) ? deviceAUUID : deviceBUUID,
                    rssi: -90 + generator.next(60)
                )
            }
        }

        harness.flushTwice()

        let statuses = await drain(harness.scanner.sensorStates, limit: 5_000).map(\.value)

        // An array, not a Set: `SensorStatus` is Equatable but deliberately not Hashable.
        // `.degraded(.scanInterrupted)` is legal here too: the storm interleaves
        // pause()/resume() with active scanning, which is exactly what produces it
        // (architecture.md §5.4, review finding M-1).
        let legal: [SensorStatus] = [
            .available,
            .unavailable(.poweredOff),
            .unavailable(.unauthorized),
            .unavailable(.unsupported),
            .degraded(.resetting),
            .degraded(.scanInterrupted),
        ]
        #expect(statuses.allSatisfy { legal.contains($0) })
        #expect(!statuses.isEmpty)

        // No two identical consecutive states.
        let hasRepeat = zip(statuses, statuses.dropFirst()).contains { $0 == $1 }
        #expect(!hasRepeat)

        // Observations never leak a device that was never monitored.
        let observations = await drain(harness.scanner.observations, limit: 500)
        #expect(observations.allSatisfy { $0.device == deviceA || $0.device == deviceB })
    }

    /// Concurrent `discover()` callers must not leave a dangling session behind: after
    /// the storm, one `stopDiscovery()` is enough to quiesce the radio.
    @Test func concurrentDiscoverySessionsQuiesceCleanly() {
        let harness = ScannerHarness()
        let scanner = harness.scanner
        // The streams are retained: a dropped stream ends its own session, which
        // would make this test pass for the wrong reason.
        let streams = StreamBox()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            streams.append(scanner.discover())
        }
        harness.flushTwice()
        harness.central?.simulateState(.poweredOn)
        harness.flush()
        #expect(harness.central?.isScanning == true)

        scanner.stopDiscovery()
        harness.flushTwice()
        #expect(harness.central?.isScanning == false)
        withExtendedLifetime(streams) {}
    }
}

/// Holds discovery streams alive across a `concurrentPerform` storm.
private final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncStream<DiscoveredDevice>] = []
    func append(_ stream: AsyncStream<DiscoveredDevice>) {
        lock.withLock { streams.append(stream) }
    }
}
