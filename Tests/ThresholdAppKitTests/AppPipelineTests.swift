import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem
@testable import ThresholdAppKit

/// The whole app, end to end, with only the boundaries faked (docs/specs/testing.md §1, L3).
///
/// Everything between `FakeScanner.emit(observation:)` and `SpyLockController.lock(reason:)` is
/// production code: the tee, the Coordinator, both Domain engines, the policy, the ledger, the
/// diagnostics bridge, and the `AppModel` the menu renders. That matters because the pieces have
/// all been tested apart, and the failure this suite exists to catch is a composition root that
/// wires them up to nothing.
@MainActor
@Suite struct AppPipelineTests {

    /// The canonical "walked away" run, matching `Tests/Fixtures/BLE/walking-away.jsonl`:
    /// strong signal until presence is confirmed, then weak signal until the departure is
    /// measured. The profile is `Fixtures.profile`, under which −45 dBm scores well above the
    /// enter threshold and −95 dBm well below the exit threshold, so no assertion here depends
    /// on where the uncertain band sits.
    private static let nearRSSI = -45
    private static let farRSSI = -95

    // MARK: - The pipeline

    @Test func walkingAwayLocksTheScreenExactlyOnceAndTheLedgerConfirmsIt() async throws {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()

        #expect(app.container.model.protectionStatus == .active)
        #expect(app.scanner.monitoredDevices == [Fixtures.deviceA])

        await app.drive(Self.nearRSSI, from: 0, through: 6)
        #expect(await app.waitFor { app.container.model.presence == .present })
        #expect(app.container.model.evidence == .measuredNear)
        // Nothing has happened yet, and nothing should have: the user is here.
        #expect(app.lock.lockCount == 0)

        // `departing` first, then `away` once `departureDelay` has passed with the signal still
        // weak — the same shape as `walking-away.expected.json`. The run stops at the second the
        // engine settles on `away` rather than at a hard-coded length, because carrying on past
        // it would cross `retryAfter` and legitimately dispatch a *second* lock: the fake screen
        // never actually locks, so an unconfirmed lock is due for a retry five seconds later.
        let departedAt = await app.drive(Self.farRSSI, from: 7, through: 60) {
            await app.coordinatorSnapshot?.presence == .away
        }
        let departure = try #require(departedAt)
        #expect(await app.waitFor { app.container.model.presence == .away })
        #expect(app.container.model.evidence == .measuredFar)

        #expect(await app.waitFor { app.lock.lockCount == 1 })
        #expect(app.lock.reasons == [.userDeparted(.measuredFar)])
        // The menu can say what changed and why, from real events rather than placeholders.
        #expect(app.container.model.lastTransition != nil)
        #expect(app.container.model.lastChangeDescription != nil)
        #expect(app.container.model.lastDecisionDescription != nil)

        // A locked screen is the only evidence that the lock took effect (PolicyEngine §6.4).
        let ledgerBeforeScreen = await app.ledger
        #expect(ledgerBeforeScreen.count == 1)
        #expect(ledgerBeforeScreen[0].stage != .confirmed)

        app.screen.push(.locked, at: Fixtures.instant(seconds: departure + 1))
        #expect(await app.waitFor { await app.ledger.first?.stage == .confirmed })

        // Silence after a confirmed lock must not produce a second one.
        await app.tick(departure + 120)
        #expect(app.lock.lockCount == 1)

        await app.container.stop()
    }

    /// security.md §2: the switch the user turned off is the last word, whatever the sensor and
    /// the engine agree about. This is the same run as above with one line changed.
    @Test func autoLockOffPreventsTheLock() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()

        app.container.setAutoLock(false)
        // The Coordinator re-evaluates on `.settingsChanged`, and with Auto Lock off the lock
        // branch declines for exactly one reason. Waiting for that rationale to come back is how
        // the test knows the actor is running on the new settings before the run starts.
        #expect(await app.waitFor { app.container.model.lastRationale.contains(.disabledBySettings) })

        await app.drive(Self.nearRSSI, from: 0, through: 6)
        await app.drive(Self.farRSSI, from: 7, through: 30)
        #expect(await app.waitFor { app.container.model.presence == .away })

        // The belief is unchanged — only the action is withheld. An app that quietly stopped
        // believing the user had left would be much harder to trust when it is switched back on.
        #expect(app.container.model.evidence == .measuredFar)
        await app.tick(50)
        #expect(app.lock.lockCount == 0)
        #expect(await app.ledger.isEmpty)
        #expect(app.container.model.protectionStatus == .active, "one switch off still counts as protected")

        await app.container.stop()
    }

    /// The Coordinator owns the sensor axis now, so the menu's status line is downstream of the
    /// engine's snapshot rather than of a second subscription to the scanner.
    @Test func sensorFaultReachesTheStatusLineAndStopsTheLock() async {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()

        await app.drive(Self.nearRSSI, from: 0, through: 6)
        #expect(await app.waitFor { app.container.model.presence == .present })

        app.scanner.emit(sensor: .unavailable(.poweredOff), at: Fixtures.instant(seconds: 7))
        #expect(await app.waitFor { app.container.model.sensorHealth == .unavailable(.poweredOff) })
        #expect(app.container.model.protectionStatus == .paused(reason: "Bluetooth is turned off"))

        await app.drive(Self.farRSSI, from: 8, through: 40)
        await app.tick(60)
        #expect(app.lock.lockCount == 0, "an untrustworthy sensor cannot produce an action")

        await app.container.stop()
    }

    /// The diagnostics bridge shares the one subscription to `Coordinator.events`, so a run that
    /// reaches the model must also reach the recorder.
    @Test func theRunIsVisibleInTheDiagnosticsExport() async throws {
        let app = PipelineHarness()
        await app.startAndBecomeHealthy()
        await app.drive(Self.nearRSSI, from: 0, through: 6)
        #expect(await app.waitFor { app.container.model.presence == .present })

        let data = try await app.container.exportDiagnostics()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("presence"))
        #expect(!text.contains(Fixtures.deviceA.raw), "a device identifier must never leave raw")

        await app.container.stop()
    }
}

// MARK: - Harness

/// An `AppContainer` with every adapter faked, plus the few helpers a scenario is written in.
///
/// The fakes are held here as their concrete types because a test drives them: `AppContainer`
/// exposes them only as existentials, which is the right shape for production and the wrong one
/// for `scanner.emit(observation:)`.
@MainActor
final class PipelineHarness {
    let clock = FakeClock(start: Fixtures.instant(seconds: 0))
    let scanner = FakeScanner()
    let screen = FakeScreenStateProvider(initial: .unlocked)
    let session = FakeSessionStateProvider(initial: .active)
    let power = FakePowerStateProvider(initial: .awake)
    let input = FakeInputActivityProvider(idle: .seconds(300))
    let lock = SpyLockController()
    let container: AppContainer

    init(settings: PolicySettings = PolicySettings(), withCalibration: Bool = true) {
        container = AppContainer.makeForTesting(
            clock: clock,
            scanner: scanner,
            screenState: screen,
            sessionState: session,
            powerState: power,
            inputActivity: input,
            lockController: lock,
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: withCalibration ? [Fixtures.record()] : []),
            settingsStore: InMemorySettingsStore(settings: settings)
        )
    }

    /// Starts the container and brings the sensor axis to `healthy`, which is where every
    /// scenario that is not about a sensor fault begins.
    func startAndBecomeHealthy() async {
        container.start()
        scanner.emit(sensor: .available, at: Fixtures.instant(seconds: 0))
        #expect(await waitFor { container.model.sensorHealth == .healthy })
    }

    // MARK: Driving

    /// Feeds one observation through the real scanner channel and waits for the engine to have
    /// consumed it.
    ///
    /// The wait is what keeps the two clocks in step. The engine reads time from the
    /// observation, while policy and the deadline scheduler read it from `clock`; emitting a
    /// whole run and only then advancing `clock` would leave policy evaluating a departure that,
    /// by its own clock, had not happened yet.
    func observe(_ rssi: Int, at seconds: Int64) async {
        clock.advance(to: Fixtures.instant(seconds: seconds))
        scanner.emit(observation: Fixtures.observation(Fixtures.deviceA, rssi: rssi, atSecond: seconds))
        let arrived = await waitFor {
            await self.coordinatorSnapshot?.devices[Fixtures.deviceA]?.estimate?.lastSeen
                == Fixtures.instant(seconds: seconds)
        }
        #expect(arrived, "observation at \(seconds)s never reached the engine")
    }

    /// One observation per second, inclusive of both ends.
    func drive(_ rssi: Int, from: Int64, through: Int64) async {
        for second in from...through {
            await observe(rssi, at: second)
        }
    }

    /// The same, but stops at the first second where `condition` holds and returns it.
    ///
    /// Lets a scenario say "drive until the engine settles on this" instead of hard-coding how
    /// many seconds that takes, which depends on the calibration profile and the filter
    /// constants and would otherwise have to be re-derived by hand whenever either moves.
    @discardableResult
    func drive(
        _ rssi: Int,
        from: Int64,
        through: Int64,
        until condition: @MainActor () async -> Bool
    ) async -> Int64? {
        for second in from...through {
            await observe(rssi, at: second)
            if await condition() { return second }
        }
        return nil
    }

    /// Moves time on without any new evidence, which is how silence is expressed.
    func tick(_ seconds: Int64) async {
        clock.advance(to: Fixtures.instant(seconds: seconds))
        await container.coordinator?.handle(.tick(Fixtures.instant(seconds: seconds)))
    }

    // MARK: Reading

    var coordinatorSnapshot: ProximitySnapshot? {
        get async { await container.coordinator?.proximitySnapshot }
    }

    var ledger: [LedgerEntry] {
        get async { await container.coordinator?.actionLedger ?? [] }
    }

    /// Polls `condition` until it holds or the attempt budget runs out.
    ///
    /// Wall-clock-free on purpose: everything being waited for is task scheduling, not domain
    /// time, and domain time belongs to `FakeClock`. Bounded so a condition that never becomes
    /// true fails the test instead of hanging the suite.
    @discardableResult
    func waitFor(attempts: Int = 5_000, _ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}
