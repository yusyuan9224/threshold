import Dispatch
import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdBluetooth

@Suite struct FakeScannerTests {

    @Test func recordsLifecycleCalls() {
        let scanner = FakeScanner()
        scanner.startScanning(for: [deviceA])
        scanner.startScanning(for: [deviceA, deviceB])
        scanner.pause()
        scanner.resume()
        scanner.pause()
        scanner.stopScanning()

        #expect(scanner.startCalls == [[deviceA], [deviceA, deviceB]])
        #expect(scanner.monitoredDevices == [deviceA, deviceB])
        #expect(scanner.pauseCount == 2)
        #expect(scanner.resumeCount == 1)
        #expect(scanner.stopScanningCount == 1)
        #expect(scanner.isScanning == false)
        #expect(scanner.isPaused == true)
    }

    @Test func emittedObservationsReachTheObservationChannel() async {
        let scanner = FakeScanner()
        scanner.emit(observation: BLEObservation(
            device: deviceA, at: MonotonicInstant(nanoseconds: 5), rssi: -61
        ))
        scanner.emit(observation: BLEObservation(
            device: deviceB, at: MonotonicInstant(nanoseconds: 6), rssi: -70
        ))
        scanner.finish()

        var received: [BLEObservation] = []
        for await observation in scanner.observations { received.append(observation) }
        #expect(received.map(\.device) == [deviceA, deviceB])
        #expect(received.map(\.rssi) == [-61, -70])
    }

    @Test func emittedSensorStatesReachTheSensorChannel() async {
        let scanner = FakeScanner()
        scanner.emit(sensor: .available, at: MonotonicInstant(nanoseconds: 1))
        scanner.emit(sensor: .degraded(.resetting), at: MonotonicInstant(nanoseconds: 2))
        scanner.emit(sensor: .unavailable(.poweredOff), at: MonotonicInstant(nanoseconds: 3))
        scanner.finish()

        var received: [Timestamped<SensorStatus>] = []
        for await status in scanner.sensorStates { received.append(status) }
        #expect(received.map(\.value) == [.available, .degraded(.resetting), .unavailable(.poweredOff)])
        #expect(received.map(\.at.nanoseconds) == [1, 2, 3])
    }

    @Test func discoveryStreamsReceiveEmittedDevicesAndFinishOnStopDiscovery() async {
        let scanner = FakeScanner()
        let stream = scanner.discover()
        #expect(scanner.discoverCallCount == 1)

        scanner.emitDiscovery(DiscoveredDevice(
            id: deviceB, advertisedName: "Bea", rssi: -70, at: MonotonicInstant(nanoseconds: 9)
        ))

        let collected = Task { () -> [DiscoveredDevice] in
            var found: [DiscoveredDevice] = []
            for await device in stream { found.append(device) }
            return found
        }
        scanner.stopDiscovery()

        let devices = await collected.value
        #expect(devices.count == 1)
        #expect(devices.first?.advertisedName == "Bea")
        #expect(scanner.stopDiscoveryCount == 1)
    }

    /// The Runtime's Coordinator will call into this from an actor, so it has to hold
    /// up under real concurrency — it is `Sendable`, not `@unchecked Sendable`.
    @Test func isSafeUnderConcurrentUse() {
        let scanner = FakeScanner()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                scanner.startScanning(for: [deviceA])
            } else {
                scanner.pause()
                scanner.resume()
            }
            scanner.emit(observation: BLEObservation(
                device: deviceA, at: MonotonicInstant(nanoseconds: Int64(index)), rssi: -60
            ))
        }
        #expect(scanner.startCalls.count == 100)
        #expect(scanner.pauseCount == 100)
        #expect(scanner.resumeCount == 100)
    }
}
