import CoreBluetooth
import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdBluetooth

@Suite struct CoreBluetoothScannerStateMappingTests {

    /// bluetooth.md §3, every row of the table.
    @Test func everyCBManagerStateMapsAsSpecified() {
        #expect(CoreBluetoothScanner.sensorStatus(for: .poweredOn) == .available)
        #expect(CoreBluetoothScanner.sensorStatus(for: .poweredOff) == .unavailable(.poweredOff))
        #expect(CoreBluetoothScanner.sensorStatus(for: .unauthorized) == .unavailable(.unauthorized))
        #expect(CoreBluetoothScanner.sensorStatus(for: .unsupported) == .unavailable(.unsupported))
        #expect(CoreBluetoothScanner.sensorStatus(for: .resetting) == .degraded(.resetting))
        // `.unknown` yields nothing: wait for the next state rather than claim health.
        #expect(CoreBluetoothScanner.sensorStatus(for: .unknown) == nil)
    }

    @Test func stateChangesReachTheSensorChannelInOrder() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()

        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateState(.resetting)
        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateState(.poweredOff)
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.resetting), .available, .unavailable(.poweredOff)])
    }

    /// CoreBluetooth redelivers states; a duplicate must not corrupt the transition
    /// sequence diagnostics reads.
    @Test func repeatedIdenticalStatesYieldOnce() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()

        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available])
    }

    /// `.unknown` is CoreBluetooth's initial state; it must not produce an event.
    @Test func unknownStateYieldsNothing() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()

        harness.central?.simulateState(.unknown)
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10)
        #expect(statuses.isEmpty)
    }

    /// Timestamps come from the injected clock, not a real one (architecture.md §4.2).
    @Test func sensorEventsAreStampedFromTheInjectedClock() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        let events = await drain(harness.scanner.sensorStates, limit: 5)
        #expect(events.count == 1)
        #expect(events.first?.at == MonotonicInstant(nanoseconds: 1_000_000))
    }
}

@Suite struct CoreBluetoothScannerObservationTests {

    @Test func observationsAreFilteredToMonitoredDevicesOnly() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)

        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -55)
        harness.central?.simulateDiscovery(identifier: deviceBUUID, rssi: -60)
        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -57)
        harness.flush()

        let observations = await drain(harness.scanner.observations, limit: 10)
        #expect(observations.map(\.device) == [deviceA, deviceA])
        #expect(observations.map(\.rssi) == [-55, -57])
    }

    /// MVP 1 is advertisement-only: `.connectionRead` is reserved but never produced
    /// (bluetooth.md §4).
    @Test func observationsAreAlwaysAdvertisementSourced() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -50)
        harness.flush()

        let observations = await drain(harness.scanner.observations, limit: 5)
        #expect(observations.allSatisfy { $0.source == .advertisement })
    }

    @Test func noObservationsAfterStopScanning() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.scanner.stopScanning()
        harness.flush()

        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -50)
        harness.flush()

        let observations = await drain(harness.scanner.observations, limit: 5)
        #expect(observations.isEmpty)
    }

    @Test func noObservationsWhilePaused() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.scanner.pause()
        harness.flush()

        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -50)
        harness.flush()

        let observations = await drain(harness.scanner.observations, limit: 5)
        #expect(observations.isEmpty)
    }
}

@Suite struct CoreBluetoothScannerLifecycleTests {

    /// architecture.md §5.4: creating the central is what raises the permission
    /// prompt, so it must not happen at construction.
    @Test func centralIsNotCreatedUntilFirstStart() {
        let harness = ScannerHarness()
        harness.flush()
        #expect(harness.central == nil)

        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        #expect(harness.central != nil)
    }

    /// An empty registry means "do not scan" — and must not prompt either.
    @Test func emptyDeviceSetCreatesNoCentral() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [])
        harness.flush()
        #expect(harness.central == nil)
    }

    @Test func discoveryAlsoCreatesTheCentralLazily() {
        let harness = ScannerHarness()
        harness.flush()
        #expect(harness.central == nil)

        _ = harness.scanner.discover()
        harness.flush()
        #expect(harness.central != nil)
    }

    @Test func scanUsesNoServiceFilterAndAllowsDuplicates() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        #expect(harness.central?.lastScanServicesWereNil == true)
        #expect(harness.central?.lastScanAllowedDuplicates == true)
    }

    @Test func scanStartsOnlyOncePoweredOn() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        #expect(harness.central?.scanCallCount == 0)

        harness.central?.simulateState(.poweredOn)
        harness.flush()
        #expect(harness.central?.scanCallCount == 1)
    }

    @Test func poweringOffStopsTheScan() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.central?.simulateState(.poweredOff)
        harness.flush()
        #expect(harness.central?.isScanning == false)
    }

    /// pause() stops the radio and remembers the intent; resume() re-issues exactly
    /// one scan (SPIKE-004: the explicit rescan is deliberate).
    @Test func pauseThenResumeReinvokesScanExactlyOnce() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()
        #expect(harness.central?.scanCallCount == 1)

        harness.scanner.pause()
        harness.flush()
        #expect(harness.central?.isScanning == false)
        #expect(harness.central?.stopScanCallCount == 1)

        harness.scanner.resume()
        harness.flush()
        #expect(harness.central?.scanCallCount == 2)
        #expect(harness.central?.isScanning == true)
    }

    /// Resuming when we were not scanning before the pause must not start the radio.
    @Test func resumeDoesNotStartScanningThatWasNeverRequested() {
        let harness = ScannerHarness()
        _ = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.scanner.stopDiscovery()
        harness.flushTwice()

        harness.scanner.pause()
        harness.scanner.resume()
        harness.flush()
        #expect(harness.central?.isScanning == false)
    }

    @Test func startScanningWithEmptySetStopsAnActiveScan() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()
        #expect(harness.central?.isScanning == true)

        harness.scanner.startScanning(for: [])
        harness.flush()
        #expect(harness.central?.isScanning == false)
    }

    @Test func redundantStartScanningDoesNotRestartTheRadio() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.startScanning(for: [deviceA, deviceB])
        harness.flush()
        #expect(harness.central?.scanCallCount == 1)
    }
}

/// architecture.md §5.4: across pause()/resume(), the sensor channel must report
/// `.degraded(.scanInterrupted)` when an active scan is stopped by pause, and
/// `.available` again once resume has reissued the scan and the central is
/// `.poweredOn`. Review finding M-1.
@Suite struct CoreBluetoothScannerPauseResumeSensorTests {

    @Test func pauseWhileScanningReportsScanInterrupted() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.pause()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.scanInterrupted)])
    }

    @Test func pauseWhileDiscoveringReportsScanInterrupted() async {
        let harness = ScannerHarness()
        let stream = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.pause()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.scanInterrupted)])
        withExtendedLifetime(stream) {}
    }

    @Test func resumeReportsAvailableAfterScanInterrupted() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.pause()
        harness.flush()
        harness.scanner.resume()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.scanInterrupted), .available])
    }

    /// Nothing was scanning at pause time, so the sensor channel must stay silent.
    @Test func pauseWhenNeverScanningEmitsNoSensorEvent() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()
        harness.scanner.stopScanning()
        harness.flush()

        harness.scanner.pause()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available])
    }

    /// Calling pause() twice must not corrupt the "no consecutive duplicate sensor
    /// events" property T-19 asserts.
    @Test func pauseTwiceEmitsOnlyOneScanInterruptedEvent() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.pause()
        harness.scanner.pause()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.scanInterrupted)])
    }

    /// A central-state change during pause must still map per bluetooth.md §3 and
    /// take precedence: resuming into `.poweredOff` must not claim `.available`.
    @Test func poweredOffWhilePausedSuppressesAvailableOnResume() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.pause()
        harness.flush()
        harness.central?.simulateState(.poweredOff)
        harness.flush()
        harness.scanner.resume()
        harness.flush()

        let statuses = await drain(harness.scanner.sensorStates, limit: 10).map(\.value)
        #expect(statuses == [.available, .degraded(.scanInterrupted), .unavailable(.poweredOff)])
    }
}

@Suite struct CoreBluetoothScannerDiscoveryTests {

    @Test func discoveryStreamFinishesOnStopDiscovery() async {
        let harness = ScannerHarness()
        let stream = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateDiscovery(identifier: deviceBUUID, name: "Bea", rssi: -70)
        harness.flush()

        // If the stream did not finish, this task would never return.
        let collected = Task { () -> [DiscoveredDevice] in
            var found: [DiscoveredDevice] = []
            for await device in stream { found.append(device) }
            return found
        }

        harness.scanner.stopDiscovery()
        harness.flush()

        let devices = await collected.value
        #expect(devices.count == 1)
        #expect(devices.first?.id == deviceB)
        #expect(devices.first?.advertisedName == "Bea")
        #expect(devices.first?.rssi == -70)
    }

    /// Discovery is the "pick your device" surface: it must show devices that are
    /// not (yet) monitored, which is exactly what the observation channel filters out.
    @Test func discoveryReportsUnmonitoredDevices() async {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        let stream = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateDiscovery(identifier: deviceBUUID, name: "Bea", rssi: -70)
        harness.flush()

        let collected = Task { () -> [DiscoveredDevice] in
            var found: [DiscoveredDevice] = []
            for await device in stream { found.append(device) }
            return found
        }
        harness.scanner.stopDiscovery()
        harness.flush()

        #expect(await collected.value.map(\.id) == [deviceB])
    }

    @Test func eachDiscoverCallReturnsANewStream() async {
        let harness = ScannerHarness()
        let first = harness.scanner.discover()
        harness.flush()
        let second = harness.scanner.discover()
        harness.flush()

        // Starting a second session supersedes and finishes the first.
        let firstCollected = Task { () -> Int in
            var count = 0
            for await _ in first { count += 1 }
            return count
        }
        #expect(await firstCollected.value == 0)

        harness.central?.simulateState(.poweredOn)
        harness.central?.simulateDiscovery(identifier: deviceAUUID, rssi: -40)
        harness.flush()

        let secondCollected = Task { () -> [DiscoveredDevice] in
            var found: [DiscoveredDevice] = []
            for await device in second { found.append(device) }
            return found
        }
        harness.scanner.stopDiscovery()
        harness.flush()
        #expect(await secondCollected.value.count == 1)
    }

    /// Discovery alone keeps the radio scanning; ending it stops the radio when no
    /// monitoring was requested.
    @Test func stopDiscoveryStopsTheRadioWhenNotMonitoring() {
        let harness = ScannerHarness()
        let stream = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()
        #expect(harness.central?.isScanning == true)

        harness.scanner.stopDiscovery()
        harness.flushTwice()
        #expect(harness.central?.isScanning == false)
        withExtendedLifetime(stream) {}
    }

    /// …but must not stop a scan that monitoring still needs.
    @Test func stopDiscoveryKeepsTheRadioWhenStillMonitoring() {
        let harness = ScannerHarness()
        harness.scanner.startScanning(for: [deviceA])
        let stream = harness.scanner.discover()
        harness.flush()
        harness.central?.simulateState(.poweredOn)
        harness.flush()

        harness.scanner.stopDiscovery()
        harness.flushTwice()
        #expect(harness.central?.isScanning == true)
        withExtendedLifetime(stream) {}
    }

    /// bluetooth.md §2: the session ends on `stopDiscovery()` *or* when the consumer
    /// goes away. Dropping the stream is the latter, and it must release the radio
    /// just as `stopDiscovery()` would — otherwise an abandoned settings screen would
    /// scan forever.
    @Test func droppingTheDiscoveryStreamEndsTheSession() {
        let harness = ScannerHarness()
        do {
            let stream = harness.scanner.discover()
            harness.flush()
            harness.central?.simulateState(.poweredOn)
            harness.flush()
            #expect(harness.central?.isScanning == true)
            withExtendedLifetime(stream) {}
        }
        harness.flushTwice()
        #expect(harness.central?.isScanning == false)
    }

    @Test func stopDiscoveryWithoutAnActiveSessionIsHarmless() {
        let harness = ScannerHarness()
        harness.scanner.stopDiscovery()
        harness.flush()
        #expect(harness.central == nil)
    }
}
