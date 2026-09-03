import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem
@testable import ThresholdAppKit

/// The seams between the composition root and the Coordinator: what the container sends when the
/// user changes something, and what it does with the one observation channel that two things need.
@MainActor
@Suite struct AppWiringTests {

    private static let nearRSSI = -45
    private static let farRSSI = -95

    // MARK: - Calibration

    /// A calibration run is the user deliberately walking away and back. The screen must not lock
    /// while they are doing it, and it must lock again as soon as they stop.
    @Test func calibrationSuspendsAutomaticActionsAndEndingItRestoresThem() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()

        let flow = app.container.beginCalibration(device: Fixtures.deviceA)
        flow.beginNear()
        #expect(await app.waitFor { app.container.model.lastRationale.contains(.disabledBySettings) })

        // The full departure shape, which would lock outside a calibration run.
        await app.drive(Self.nearRSSI, from: 0, through: 6)
        let mutedDeparture = await app.drive(Self.farRSSI, from: 7, through: 60) {
            await app.coordinatorSnapshot?.presence == .away
        }
        #expect(mutedDeparture != nil, "the engine still forms the belief; only the action is withheld")
        #expect(app.lock.lockCount == 0)
        // The user never turned anything off, so the switch in the menu still reads as on.
        #expect(app.container.model.settings.autoLock)

        // Ending the run resets the engine *before* it re-enables Auto Lock. The belief formed
        // during the measurement is that the user is away, and acting on it the moment they sit
        // back down would lock the screen in their face.
        app.container.endCalibration()
        #expect(await app.waitFor { await app.coordinatorSnapshot?.presence != .away })
        #expect(app.lock.lockCount == 0, "finishing a calibration must not lock the screen")

        let start = (mutedDeparture ?? 60) + 1
        await app.drive(Self.nearRSSI, from: start, through: start + 6)
        let departure = await app.drive(Self.farRSSI, from: start + 7, through: start + 60) {
            await app.coordinatorSnapshot?.presence == .away
        }
        #expect(departure != nil)
        #expect(await app.waitFor { app.lock.lockCount == 1 })

        await app.container.stop()
    }

    /// `scanner.observations` is single-consumer. The Coordinator iterates it for the whole life
    /// of the app, so a calibration session reading the same property would take roughly half the
    /// advertisements away from it and get half of its own — a run that quietly needs twice as
    /// long, or fails on `insufficientSamples`, and only in the built app.
    @Test func calibrationAndTheEngineEachSeeEveryObservation() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()

        let flow = app.container.beginCalibration(device: Fixtures.deviceA)
        flow.beginNear()

        let samples = Fixtures.steadySamples(centre: Self.nearRSSI, count: 25)
        for sample in samples {
            app.clock.advance(to: Fixtures.instant(seconds: sample.second))
            app.scanner.emit(observation: Fixtures.observation(Fixtures.deviceA, rssi: sample.rssi, atSecond: sample.second))
        }

        let allReachedCalibration = await app.waitFor { flow.sampleCount(for: .near) == samples.count }
        #expect(allReachedCalibration, "the calibration session lost samples to the Coordinator")

        let last = samples[samples.count - 1].second
        let reachedEngine = await app.waitFor {
            await app.coordinatorSnapshot?.devices[Fixtures.deviceA]?.estimate?.lastSeen
                == Fixtures.instant(seconds: last)
        }
        #expect(reachedEngine, "the Coordinator lost samples to the calibration session")

        app.container.endCalibration()
        await app.container.stop()
    }

    // MARK: - Devices and gate

    /// Registering the first device is what turns a fresh install into a running pipeline: the
    /// Coordinator has to be told, because it fixes its device set when it builds the engine.
    @Test func registeringADeviceRebuildsTheEngineAroundIt() async throws {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(scanner: scanner)
        container.start()
        #expect(scanner.monitoredDevices.isEmpty, "a fresh install must raise no permission prompt")

        try container.registerDevice(RegisteredDevice(id: Fixtures.deviceA, name: "Phone"))
        #expect(scanner.monitoredDevices == [Fixtures.deviceA])

        // The rebuild is queued behind the input pump, so give the actor a chance to run it.
        let rebuilt = await waitUntilAsync {
            await container.coordinator?.proximitySnapshot.devices[Fixtures.deviceA] != nil
        }
        #expect(rebuilt, "the Coordinator was never told about the new trusted device")

        await container.stop()
    }

    /// A calibration that arms the gate has to reach the Coordinator, or the pipeline keeps
    /// refusing to act for a reason the menu no longer shows.
    @Test func applyingACalibrationArmsTheRunningPipeline() async throws {
        let app = PipelineHarness(withCalibration: false)
        await app.startAndBecomeHealthy()
        #expect(app.container.model.calibrationGate == .notArmed(.noProfile))

        await app.drive(Self.nearRSSI, from: 0, through: 6)
        #expect(await app.waitFor {
            app.container.model.lastRationale.contains(.preconditionUnsatisfied(.calibration))
                || app.container.model.lastRationale.contains(.preconditionIndeterminate(.calibration))
        })

        try app.container.applyCalibration(Fixtures.record())
        #expect(app.container.model.calibrationGate.isArmed)
        #expect(await app.waitFor {
            !app.container.model.lastRationale.contains(.preconditionUnsatisfied(.calibration))
                && !app.container.model.lastRationale.contains(.preconditionIndeterminate(.calibration))
        })

        await app.container.stop()
    }

    // MARK: - Shutdown

    /// architecture.md §3: the Coordinator stops before the scanner does, because the Coordinator
    /// is the thing that restarts scanning by itself.
    @Test func stopReleasesTheCoordinatorAndThenTheScanner() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()
        #expect(app.container.coordinator != nil)

        await app.container.stop()

        #expect(app.container.coordinator == nil)
        #expect(app.scanner.stopScanningCount == 1)
        #expect(app.scanner.stopDiscoveryCount == 1)

        // Nothing left listening: a late advertisement changes nothing and dispatches nothing.
        let before = app.container.model.presence
        app.scanner.emit(observation: Fixtures.observation(Fixtures.deviceA, rssi: Self.nearRSSI, atSecond: 99))
        for _ in 0..<200 { await Task.yield() }
        #expect(app.container.model.presence == before)
        #expect(app.lock.lockCount == 0)
    }

    /// Stopping twice is what happens when the user picks Quit and AppKit then calls the
    /// termination hook. It must not trap and must not double-stop the scanner.
    @Test func stoppingTwiceIsHarmless() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()
        await app.container.stop()
        await app.container.stop()
        #expect(app.scanner.stopScanningCount == 2, "the second stop is a no-op on an already-stopped scanner")
        #expect(app.container.coordinator == nil)
    }
}

/// `waitUntil`'s async sibling, for conditions that have to hop to an actor.
@MainActor
func waitUntilAsync(attempts: Int = 5_000, _ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
