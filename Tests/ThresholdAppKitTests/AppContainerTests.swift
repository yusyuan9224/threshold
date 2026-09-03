import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdAppKit

/// `AppContainer` is the composition root, so these tests are about wiring and persistence,
/// not about proximity logic. Every adapter is a Fake (architecture.md §3's `TestContainer`).
@MainActor
@Suite struct AppContainerTests {

    @Test func testContainerBuildsAndStartsWithNothingPersisted() async {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(scanner: scanner)
        container.start()

        #expect(container.model.startupIssues.isEmpty)
        #expect(container.model.registry.isEmpty)
        #expect(container.needsOnboarding)
        #expect(container.model.calibrationGate == .notArmed(.noProfile))
        #expect(container.model.protectionStatus == .notArmed(reason: "set up a trusted device"))
        // An empty device set means "do not scan", so a fresh install raises no permission prompt.
        #expect(scanner.monitoredDevices.isEmpty)
        await container.stop()
    }

    @Test func storedDevicesSettingsAndCalibrationAreLoadedAtStart() async {
        let scanner = FakeScanner()
        var settings = PolicySettings()
        settings.wakeOnReturn = false
        let container = AppContainer.makeForTesting(
            scanner: scanner,
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: [Fixtures.record()]),
            settingsStore: InMemorySettingsStore(settings: settings)
        )
        container.start()

        #expect(container.model.trustedDeviceName == "Phone")
        #expect(container.model.settings.wakeOnReturn == false)
        #expect(container.model.calibrationGate == .armed(Fixtures.profile))
        #expect(container.needsOnboarding == false)
        #expect(scanner.monitoredDevices == [Fixtures.deviceA])
        await container.stop()
    }

    /// A file this build cannot read is reported, never silently replaced with defaults.
    @Test func storeFailuresBecomeVisibleStartupIssues() async {
        let deviceStore = InMemoryDeviceStore()
        deviceStore.failLoad(with: .unsupportedSchemaVersion(file: "devices.json", found: 2, supported: 1))
        let container = AppContainer.makeForTesting(deviceStore: deviceStore)
        container.start()

        #expect(container.model.startupIssues.count == 1)
        #expect(container.model.startupIssues[0].contains("devices.json"))
        #expect(container.model.startupIssues[0].contains("Nothing was changed."))
        await container.stop()
    }

    @Test func settingsChangesArePersistedImmediately() async throws {
        let store = InMemorySettingsStore()
        let container = AppContainer.makeForTesting(settingsStore: store)
        container.start()

        container.setAutoLock(false)
        container.setSilenceLock(.never)
        container.setLockOnDepartureThenSilent(false)

        let saved = try #require(try store.load())
        #expect(saved.autoLock == false)
        #expect(saved.silenceLock == .never)
        #expect(saved.lockOnDepartureThenSilent == false)
        #expect(store.saveCount == 3)
        await container.stop()
    }

    @Test func settingAValueItAlreadyHasWritesNothing() async {
        let store = InMemorySettingsStore()
        let container = AppContainer.makeForTesting(settingsStore: store)
        container.start()
        container.setAutoLock(true)
        #expect(store.saveCount == 0)
        await container.stop()
    }

    @Test func registeringADeviceStartsScanningForIt() async throws {
        let scanner = FakeScanner()
        let deviceStore = InMemoryDeviceStore()
        let container = AppContainer.makeForTesting(scanner: scanner, deviceStore: deviceStore)
        container.start()

        try container.registerDevice(RegisteredDevice(id: Fixtures.deviceA, name: "Phone"))

        #expect(container.model.registry.name(for: Fixtures.deviceA) == "Phone")
        #expect(try deviceStore.load() == [DeviceRecord(device: Fixtures.deviceA, name: "Phone")])
        #expect(scanner.monitoredDevices == [Fixtures.deviceA])
        await container.stop()
    }

    @Test func renamingWritesTheNewNameAndIgnoresABlankOne() async throws {
        let deviceStore = InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")])
        let container = AppContainer.makeForTesting(deviceStore: deviceStore)
        container.start()

        try container.renameDevice(Fixtures.deviceA, to: "  My phone  ")
        #expect(container.model.registry.name(for: Fixtures.deviceA) == "My phone")

        try container.renameDevice(Fixtures.deviceA, to: "   ")
        #expect(container.model.registry.name(for: Fixtures.deviceA) == "My phone")
        await container.stop()
    }

    /// A profile only means something for the device it was measured from, so removing the
    /// device removes its calibration too — otherwise re-adding an identifier later would
    /// silently arm automation on a stale measurement.
    @Test func removingADeviceClearsItsCalibration() async throws {
        let calibrationStore = InMemoryCalibrationStore(records: [Fixtures.record()])
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(
            scanner: scanner,
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: calibrationStore
        )
        container.start()
        #expect(container.model.calibrationGate.isArmed)

        try container.removeDevice(Fixtures.deviceA)

        #expect(container.model.registry.isEmpty)
        #expect(try calibrationStore.load().isEmpty)
        #expect(container.model.calibrationGate == .notArmed(.noProfile))
        #expect(container.needsOnboarding)
        #expect(scanner.monitoredDevices.isEmpty)
        await container.stop()
    }

    @Test func removingOneDeviceLeavesAnotherDevicesCalibrationAlone() async throws {
        let calibrationStore = InMemoryCalibrationStore(records: [
            Fixtures.record(device: Fixtures.deviceA),
            Fixtures.record(device: Fixtures.deviceB),
        ])
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [
                DeviceRecord(device: Fixtures.deviceA, name: "Phone"),
                DeviceRecord(device: Fixtures.deviceB, name: "Watch"),
            ]),
            calibrationStore: calibrationStore
        )
        container.start()

        try container.removeDevice(Fixtures.deviceB)
        let remaining = try calibrationStore.load()
        #expect(remaining.map(\.device) == [Fixtures.deviceA])
        #expect(container.model.calibrationGate.isArmed)
        await container.stop()
    }

    @Test func resetCalibrationDisarmsButKeepsTheDevice() async throws {
        let calibrationStore = InMemoryCalibrationStore(records: [Fixtures.record()])
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: calibrationStore
        )
        container.start()

        try container.resetCalibration()

        #expect(try calibrationStore.load().isEmpty)
        #expect(container.model.calibrationGate == .notArmed(.noProfile))
        #expect(container.model.trustedDeviceName == "Phone")
        await container.stop()
    }

    /// A failed write must not leave the in-memory gate claiming a calibration that is not on
    /// disk — the next launch would disagree with what the user was just shown.
    @Test func aFailedCalibrationWriteRollsBackTheInMemoryRecords() async {
        let calibrationStore = InMemoryCalibrationStore()
        calibrationStore.failSave(with: .writeFailed(file: "calibration.json", message: "NSCocoaErrorDomain 513"))
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: calibrationStore
        )
        container.start()

        #expect(throws: StoreError.self) { try container.applyCalibration(Fixtures.record()) }
        #expect(container.model.calibrationGate == .notArmed(.noProfile))
        await container.stop()
    }

    @Test func applyingACalibrationReplacesThePreviousOneForTheSameDevice() async throws {
        let calibrationStore = InMemoryCalibrationStore(records: [Fixtures.record()])
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: calibrationStore
        )
        container.start()

        let updated = CalibrationProfile(nearBaseline: -45, farBaseline: -85, noise: 2, midpoint: -65, slope: 10)
        try container.applyCalibration(Fixtures.record(profile: updated))

        let stored = try calibrationStore.load()
        #expect(stored.count == 1)
        #expect(stored[0].profile == updated)
        #expect(container.model.calibrationGate == .armed(updated))
        await container.stop()
    }

    // MARK: - Gate

    @Test func aProfileMeasuredOnAnotherMacDoesNotArm() async {
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: [Fixtures.record(macIdentity: "another-mac")])
        )
        container.start()
        #expect(container.model.calibrationGate == .notArmed(.macMismatch))
        await container.stop()
    }

    @Test func anOSMajorUpgradeAsksForRevalidation() async {
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: [Fixtures.record(osMajorVersion: 25)]),
            osMajorVersion: 26
        )
        container.start()
        #expect(container.model.calibrationGate == .notArmed(.needsRevalidation(osMajorChanged: true)))
        await container.stop()
    }

    /// A Mac that will not identify itself disarms rather than defaulting to a value that
    /// would compare equal everywhere.
    @Test func anUnidentifiableMacDisarms() async {
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: [Fixtures.record()]),
            macIdentity: nil
        )
        container.start()
        #expect(container.model.calibrationGate == .notArmed(.macMismatch))
        await container.stop()
    }

    // MARK: - Sensor channel and login item

    @Test func theSensorChannelReachesTheModel() async {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(
            scanner: scanner,
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")]),
            calibrationStore: InMemoryCalibrationStore(records: [Fixtures.record()])
        )
        container.start()

        scanner.emit(sensor: .unavailable(.poweredOff), at: Fixtures.instant(seconds: 1))
        let paused = await waitUntil { container.model.sensorHealth == .unavailable(.poweredOff) }
        #expect(paused)
        #expect(container.model.protectionStatus == .paused(reason: "Bluetooth is turned off"))

        scanner.emit(sensor: .available, at: Fixtures.instant(seconds: 2))
        let healthy = await waitUntil { container.model.sensorHealth == .healthy }
        #expect(healthy)
        #expect(container.model.protectionStatus == .active)
        await container.stop()
    }

    @Test func loginItemRegistrationIsReflectedInTheModel() async throws {
        let loginItem = FakeLoginItemController()
        let container = AppContainer.makeForTesting(loginItem: loginItem)
        container.start()
        #expect(container.model.loginItemStatus == .known(.notRegistered))

        try container.setLoginItemEnabled(true)
        #expect(loginItem.registerCount == 1)
        #expect(container.model.loginItemStatus == .known(.enabled))

        try container.setLoginItemEnabled(false)
        #expect(loginItem.unregisterCount == 1)
        #expect(container.model.loginItemStatus == .known(.notRegistered))
        await container.stop()
    }

    @Test func aFailedLoginItemRegistrationStillRefreshesTheDisplayedStatus() async {
        let loginItem = FakeLoginItemController()
        loginItem.failNextRegister(with: .registrationFailed("denied"))
        let container = AppContainer.makeForTesting(loginItem: loginItem)
        container.start()

        #expect(throws: LoginItemError.self) { try container.setLoginItemEnabled(true) }
        #expect(container.model.loginItemStatus == .known(.notRegistered))
        await container.stop()
    }

    // MARK: - Onboarding wiring

    @Test func onboardingRegistersThroughTheContainerAndArmsScanning() async {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(scanner: scanner)
        container.start()
        let flow = container.makeOnboardingFlow()

        flow.startScanning()
        #expect(scanner.discoverCallCount == 1)

        flow.discovered(Fixtures.discovered(Fixtures.deviceA, name: "Phone", rssi: -50, atSecond: 0))
        flow.select(Fixtures.deviceA)
        flow.registerSelectedDevice()

        #expect(container.model.trustedDeviceName == "Phone")
        #expect(scanner.monitoredDevices == [Fixtures.deviceA])
        #expect(scanner.stopDiscoveryCount == 1)

        flow.skipCalibration()
        flow.finish()
        #expect(container.needsOnboarding == false)
        #expect(container.onboarding == nil)
        await container.stop()
    }

    /// HIGH fix: the container's sensor channel must also reach onboarding, so the device
    /// picker can show a `.blocked` banner instead of spinning on "Looking for devices…"
    /// forever when CoreBluetooth reports `.unauthorized` or `.poweredOff` after "Start
    /// scanning" — and must ask the scanner for a fresh discovery session once it recovers.
    @Test func onboardingDiscoveryStateFollowsTheRealSensorChannel() async {
        let scanner = FakeScanner()
        let container = AppContainer.makeForTesting(scanner: scanner)
        container.start()
        let flow = container.makeOnboardingFlow()

        flow.startScanning()
        #expect(scanner.discoverCallCount == 1)

        scanner.emit(sensor: .unavailable(.unauthorized), at: Fixtures.instant(seconds: 1))
        let unauthorizedBlocked = await waitUntil {
            flow.discoveryState == .blocked(reason: .unauthorized, canOpenSettings: true)
        }
        #expect(unauthorizedBlocked)

        scanner.emit(sensor: .unavailable(.poweredOff), at: Fixtures.instant(seconds: 2))
        let poweredOffBlocked = await waitUntil {
            flow.discoveryState == .blocked(reason: .poweredOff, canOpenSettings: true)
        }
        #expect(poweredOffBlocked)

        scanner.emit(sensor: .available, at: Fixtures.instant(seconds: 3))
        let recovered = await waitUntil { flow.discoveryState == .scanning }
        #expect(recovered)
        // Recovering from blocked asked for a fresh discovery session.
        let restarted = await waitUntil { scanner.discoverCallCount == 2 }
        #expect(restarted)
        await container.stop()
    }

    @Test func calibrateFromTheMenuNeedsATrustedDevice() async {
        let container = AppContainer.makeForTesting()
        container.start()
        container.presentCalibrationOnboarding()
        #expect(container.onboarding == nil)
        await container.stop()
    }

    @Test func calibrateFromTheMenuOpensStraightAtTheCalibrationStep() async {
        let container = AppContainer.makeForTesting(
            deviceStore: InMemoryDeviceStore(records: [DeviceRecord(device: Fixtures.deviceA, name: "Phone")])
        )
        container.start()
        container.presentCalibrationOnboarding()
        #expect(container.onboarding?.step == .calibrate)
        await container.stop()
    }

    // MARK: - Diagnostics

    @Test func diagnosticsExportProducesTheDeIdentifiedEnvelope() async throws {
        let container = AppContainer.makeForTesting()
        container.start()
        await container.recorder.record(
            category: .systemLifecycle,
            message: "app started",
            monotonicNanoseconds: 0
        )
        let data = try await container.exportDiagnostics()
        let text = String(decoding: data, as: UTF8.self)
        // `JSONEncoder` escapes the slash in the format string, so match the parts around it.
        #expect(text.contains("threshold-diagnostics"))
        #expect(text.contains("app started"))
        await container.stop()
    }
}
