import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdAppKit

@MainActor
@Suite struct CalibrationFlowTests {

    private let environment = CalibrationEnvironment(
        macIdentity: "test-mac",
        osMajorVersion: 26,
        appVersion: "test",
        nowUnixSeconds: 1_700_000_000
    )

    /// Runs one phase's worth of samples through the flow, as the scanner's observation stream
    /// would deliver them.
    private func feed(_ flow: CalibrationFlow, centre: Int, count: Int = 25, fromSecond: Int64 = 0) {
        for sample in Fixtures.steadySamples(centre: centre, count: count, fromSecond: fromSecond) {
            flow.ingest(Fixtures.observation(flow.device, rssi: sample.rssi, atSecond: sample.second))
        }
    }

    @Test func aWellSeparatedRunProducesASavableRecord() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50)
        #expect(flow.isComplete(.near))
        flow.completeNear()
        flow.beginFar()
        feed(flow, centre: -80, fromSecond: 60)
        #expect(flow.isComplete(.far))

        guard case .success(let record) = flow.finish(environment: environment) else {
            Issue.record("expected a record, got \(flow.stage)")
            return
        }
        #expect(record.device == Fixtures.deviceA)
        #expect(record.macIdentity == "test-mac")
        #expect(record.osMajorVersion == 26)
        #expect(record.appVersion == "test")
        #expect(record.createdAtUnixSeconds == 1_700_000_000)
        #expect(record.profile.nearBaseline > record.profile.farBaseline)
        // A record carrying the display-only default would be refused by the validator.
        #expect(record.profile != CalibrationProfile.default)
        #expect(flow.stage == .succeeded(record.profile))
    }

    /// Two spots the radio cannot tell apart. The user is told to walk further, not that they
    /// did something wrong.
    @Test func twoSimilarSpotsFailAsOverlap() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -60)
        flow.completeNear()
        flow.beginFar()
        feed(flow, centre: -58, fromSecond: 60)

        #expect(flow.finish(environment: environment) == .failure(.measurement(.overlap)))
        #expect(flow.failureMessage?.contains("too similar") == true)
    }

    @Test func aShortRunFailsAsInsufficientSamples() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50, count: 5)
        #expect(flow.isComplete(.near) == false)

        #expect(flow.finish(environment: environment) == .failure(.measurement(.insufficientSamples(phase: .near))))
        #expect(flow.failureMessage?.contains("stay put") == true)
    }

    /// A phase that met its sample count but not its 20-second span is still short. The
    /// progress bar must not have looked full.
    @Test func enoughSamplesInTooShortASpanIsStillIncomplete() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        for index in 0..<30 {
            flow.ingest(Fixtures.observation(Fixtures.deviceA, rssi: -50, atSecond: 0))
            _ = index
        }
        #expect(flow.sampleCount(for: .near) == 30)
        #expect(flow.isComplete(.near) == false)
        #expect(flow.progress(for: .near) == 0)
    }

    @Test func aNoisyRoomFailsAsTooNoisy() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        // Spread across five levels 8 dB apart, so the median absolute deviation is 8 dB —
        // above the 6 dB the policy allows. An alternating two-level pattern would not do:
        // its MAD is zero, because most samples sit exactly on the median.
        for index in 0..<25 {
            flow.ingest(Fixtures.observation(Fixtures.deviceA, rssi: -50 + (index % 5) * 8, atSecond: Int64(index)))
        }
        flow.completeNear()
        flow.beginFar()
        feed(flow, centre: -90, fromSecond: 60)

        #expect(flow.finish(environment: environment) == .failure(.measurement(.tooNoisy(phase: .near))))
    }

    /// security.md §2 rule 4 rests on `macIdentity`. Without a real one the run is refused
    /// rather than saved with a placeholder that would compare equal on every Mac.
    @Test func anUnidentifiableMacRefusesToProduceARecord() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50)
        flow.completeNear()
        flow.beginFar()
        feed(flow, centre: -80, fromSecond: 60)

        let anonymous = CalibrationEnvironment(macIdentity: nil, osMajorVersion: 26, appVersion: "test", nowUnixSeconds: 0)
        #expect(flow.finish(environment: anonymous) == .failure(.machineIdentityUnavailable))
        #expect(flow.stage == .failed(.machineIdentityUnavailable))
        #expect(flow.failureMessage?.contains("identify itself") == true)
    }

    @Test func observationsFromOtherDevicesAreIgnored() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        for second in 0..<25 {
            flow.ingest(Fixtures.observation(Fixtures.deviceB, rssi: -30, atSecond: Int64(second)))
        }
        #expect(flow.sampleCount(for: .near) == 0)
    }

    /// The seconds a user spends reading "now walk to where you usually leave" must not land
    /// in either phase.
    @Test func observationsBetweenPhasesAreDropped() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50, count: 25)
        flow.completeNear()
        for second in Int64(30)..<40 {
            flow.ingest(Fixtures.observation(Fixtures.deviceA, rssi: -55, atSecond: second))
        }
        #expect(flow.sampleCount(for: .near) == 25)
        #expect(flow.sampleCount(for: .far) == 0)
    }

    @Test func progressReachesOneOnlyWhenBothMinimumsAreMet() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50, count: 10)
        #expect(flow.progress(for: .near) < 1)
        feed(flow, centre: -50, count: 15, fromSecond: 10)
        #expect(flow.progress(for: .near) == 1)
    }

    @Test func restartingClearsEverySampleFromThePreviousAttempt() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50)
        flow.beginNear()
        #expect(flow.sampleCount(for: .near) == 0)
        #expect(flow.stage == .measuring(.near))
    }

    @Test func aSaveFailureOverridesASuccessfulMeasurement() {
        let flow = CalibrationFlow(device: Fixtures.deviceA)
        flow.beginNear()
        feed(flow, centre: -50)
        flow.completeNear()
        flow.beginFar()
        feed(flow, centre: -80, fromSecond: 60)
        _ = flow.finish(environment: environment)

        flow.saveFailed("calibration.json could not be saved")
        #expect(flow.stage == .failed(.saveFailed("calibration.json could not be saved")))
        #expect(flow.failureMessage?.contains("calibration.json") == true)
    }
}

/// The same three outcomes, but driven through `FakeScanner`'s observation stream and the
/// container's calibration plumbing, so the wiring between the two is covered and not just the
/// state machine on its own.
@MainActor
@Suite struct CalibrationOverTheScannerTests {

    private func run(centreNear: Int, centreFar: Int, count: Int = 25) async -> (CalibrationFlow, AppContainer, FakeScanner) {
        let scanner = FakeScanner()
        // The device has to be registered for the gate to mean anything: `currentGate()` is
        // computed for the trusted device, and there is no such thing as a calibration for a
        // device the user never chose.
        let container = AppContainer.makeForTesting(
            scanner: scanner,
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")])
        )
        container.start()
        let flow = container.beginCalibration(device: Fixtures.deviceA)

        flow.beginNear()
        await emit(scanner, flow: flow, phase: .near, centre: centreNear, count: count, fromSecond: 0)
        flow.completeNear()
        flow.beginFar()
        await emit(scanner, flow: flow, phase: .far, centre: centreFar, count: count, fromSecond: 60)
        return (flow, container, scanner)
    }

    private func emit(_ scanner: FakeScanner, flow: CalibrationFlow, phase: CalibrationPhase, centre: Int, count: Int, fromSecond: Int64) async {
        for sample in Fixtures.steadySamples(centre: centre, count: count, fromSecond: fromSecond) {
            scanner.emit(observation: Fixtures.observation(Fixtures.deviceA, rssi: sample.rssi, atSecond: sample.second))
        }
        let arrived = await waitUntil { flow.sampleCount(for: phase) == count }
        #expect(arrived, "observations did not reach the calibration session")
    }

    /// Scanning is narrowed to the device being calibrated, so no other trusted device's
    /// advertisements can blur the baselines.
    @Test func calibrationScansForOnlyTheDeviceBeingMeasured() async {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(scanner: scanner)
        container.beginCalibration(device: Fixtures.deviceA)
        #expect(scanner.monitoredDevices == [Fixtures.deviceA])
        container.endCalibration()
        #expect(scanner.monitoredDevices.isEmpty)
        await container.stop()
    }

    @Test func scannerFedRunSucceedsAndPersists() async throws {
        let (flow, container, _) = await run(centreNear: -50, centreFar: -80)
        guard case .success(let record) = flow.finish(environment: container.calibrationEnvironment) else {
            Issue.record("expected success, got \(flow.stage)")
            return
        }
        try container.applyCalibration(record)
        #expect(container.model.calibrationGate.isArmed)
        await container.stop()
    }

    @Test func scannerFedOverlapFails() async {
        let (flow, container, _) = await run(centreNear: -60, centreFar: -58)
        #expect(flow.finish(environment: container.calibrationEnvironment) == .failure(.measurement(.overlap)))
        #expect(container.model.calibrationGate.isArmed == false)
        await container.stop()
    }

    @Test func scannerFedShortRunFailsAsInsufficientSamples() async {
        let (flow, container, _) = await run(centreNear: -50, centreFar: -80, count: 5)
        #expect(flow.finish(environment: container.calibrationEnvironment)
            == .failure(.measurement(.insufficientSamples(phase: .near))))
        await container.stop()
    }
}
