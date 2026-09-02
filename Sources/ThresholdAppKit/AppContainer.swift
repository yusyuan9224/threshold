import Foundation
import Observation
import ThresholdBluetooth
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem

/// Adapts the system-wide `MonotonicClock` to the single operation the Bluetooth target
/// declares for itself.
///
/// `ThresholdBluetooth` must not depend on `ThresholdSystem` (architecture.md §2.2), so it
/// declares `BLEClock` — just `now()` — and the composition root bridges the two. This tiny
/// struct is that bridge, and it is the reason the app has exactly one clock rather than two
/// that can disagree.
struct BLEClockAdapter: BLEClock {
    let clock: any MonotonicClock
    func now() -> MonotonicInstant { clock.now() }
}

/// The composition root (architecture.md §3): the only place in the app where a concrete
/// adapter is constructed.
///
/// It owns the production adapters, the stores, the `DiagnosticsRecorder` actor, every
/// long-lived `Task`, and the `AppModel` the UI renders. Domain, Bluetooth and System never
/// construct each other; everything meets here.
///
/// `@MainActor` because it is the lifecycle owner and it writes `AppModel`, which the UI
/// observes. The high-frequency work stays off this actor: the recorder is an actor of its
/// own, the scanner is confined to its own serial queue, and this class only ever receives
/// already-`Sendable` values across those boundaries.
///
/// **Coordinator seam.** The `Coordinator` actor (architecture.md §5) is being written on
/// `feat/runtime-coordinator` and is deliberately not referenced here. Until it lands, this
/// container drives the sensor axis straight from the scanner's `sensorStates` channel and
/// leaves presence at `unknown(.initial)`, which the UI shows honestly. Wiring the Coordinator
/// in means replacing `runSensorChannel()` with a subscription that feeds `AppEventSink`; no
/// other method changes.
@MainActor
@Observable
public final class AppContainer {

    // MARK: - Adapters (constructed here and nowhere else)

    public let clock: any MonotonicClock
    public let scanner: any BLEScanning
    public let screenState: any ScreenStateProviding
    public let sessionState: any SessionStateProviding
    public let powerState: any PowerStateProviding
    public let inputActivity: any InputActivityProviding
    public let lockController: any LockControlling
    public let wakeController: any WakeControlling
    public let loginItem: any LoginItemControlling
    public let deviceStore: any DeviceStore
    public let calibrationStore: any CalibrationStore
    public let settingsStore: any SettingsStore
    public let recorder: DiagnosticsRecorder

    // MARK: - Environment

    public let calibrationPolicy: CalibrationPolicy
    /// `MacIdentity.current()` in production. `nil` is a real outcome and is never faked.
    public let macIdentity: String?
    public let osMajorVersion: Int
    public let appVersion: String
    private let nowUnixSeconds: @Sendable () -> Int64

    // MARK: - Observable state

    public let model: AppModel
    /// True on a first launch, or whenever the last trusted device has been removed.
    public internal(set) var needsOnboarding: Bool = false
    public internal(set) var onboarding: OnboardingFlow?
    public internal(set) var calibration: CalibrationFlow?

    /// Calibration records as loaded and as saved. Kept in memory because the gate has to be
    /// recomputed on every device change and re-reading a JSON file to answer that would make
    /// a store failure part of a UI interaction.
    var calibrationRecords: [CalibrationRecord] = []

    private var sensorTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    var discoveryTask: Task<Void, Never>?
    var calibrationTask: Task<Void, Never>?

    /// A launch problem discovered before `start()` had somewhere to report it.
    private var deferredStartupIssue: String?

    // MARK: - Construction

    public init(
        clock: any MonotonicClock,
        scanner: any BLEScanning,
        screenState: any ScreenStateProviding,
        sessionState: any SessionStateProviding,
        powerState: any PowerStateProviding,
        inputActivity: any InputActivityProviding,
        lockController: any LockControlling,
        wakeController: any WakeControlling,
        loginItem: any LoginItemControlling,
        deviceStore: any DeviceStore,
        calibrationStore: any CalibrationStore,
        settingsStore: any SettingsStore,
        recorder: DiagnosticsRecorder,
        calibrationPolicy: CalibrationPolicy = CalibrationPolicy(),
        macIdentity: String?,
        osMajorVersion: Int,
        appVersion: String,
        nowUnixSeconds: @escaping @Sendable () -> Int64
    ) {
        self.clock = clock
        self.scanner = scanner
        self.screenState = screenState
        self.sessionState = sessionState
        self.powerState = powerState
        self.inputActivity = inputActivity
        self.lockController = lockController
        self.wakeController = wakeController
        self.loginItem = loginItem
        self.deviceStore = deviceStore
        self.calibrationStore = calibrationStore
        self.settingsStore = settingsStore
        self.recorder = recorder
        self.calibrationPolicy = calibrationPolicy
        self.macIdentity = macIdentity
        self.osMajorVersion = osMajorVersion
        self.appVersion = appVersion
        self.nowUnixSeconds = nowUnixSeconds
        self.model = AppModel()
    }

    /// The production graph.
    ///
    /// Creating `CoreBluetoothScanner` here does **not** raise the Bluetooth permission
    /// prompt: the scanner defers `CBCentralManager` creation until it is actually asked to
    /// scan or discover (architecture.md §5.4), so a Mac with no trusted device yet shows no
    /// system dialog until the user presses "Start scanning" in onboarding.
    public static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            appVersion: String? = nil) throws -> AppContainer {
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        let directory = try ApplicationSupportDirectory.url(bundleIdentifier: identifier)
        return makeLive(
            deviceStore: JSONFileDeviceStore(directory: directory),
            calibrationStore: JSONFileCalibrationStore(directory: directory),
            settingsStore: JSONFileSettingsStore(directory: directory),
            appVersion: appVersion ?? Self.bundleShortVersion()
        )
    }

    /// `live()`, but never fatal.
    ///
    /// The only way `live()` throws is a missing or unusable Application Support directory,
    /// and refusing to launch over that would leave a user with no way to see *why*. Instead
    /// the app comes up with in-memory stores — proximity still works for this run — and says
    /// on its first screen that nothing will be remembered. Failing loudly and visibly beats
    /// both crashing and quietly writing somewhere else.
    public static func bootstrap(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                                 appVersion: String? = nil) -> AppContainer {
        do {
            return try live(bundleIdentifier: bundleIdentifier, appVersion: appVersion)
        } catch {
            let container = makeLive(
                deviceStore: InMemoryDeviceStore(),
                calibrationStore: InMemoryCalibrationStore(),
                settingsStore: InMemorySettingsStore(),
                appVersion: appVersion ?? Self.bundleShortVersion()
            )
            container.deferredStartupIssue =
                "Threshold could not open its storage folder, so your device, calibration and settings will be forgotten when you quit. \(StoreErrorText.describe(error))"
            return container
        }
    }

    /// The production adapter graph, with persistence left to the caller.
    private static func makeLive(
        deviceStore: any DeviceStore,
        calibrationStore: any CalibrationStore,
        settingsStore: any SettingsStore,
        appVersion: String
    ) -> AppContainer {
        let clock = ContinuousMonotonicClock()
        let screen = MacOSScreenStateProvider(clock: clock)
        let session = MacOSSessionStateProvider(clock: clock)

        return AppContainer(
            clock: clock,
            scanner: CoreBluetoothScanner(clock: BLEClockAdapter(clock: clock)),
            screenState: screen,
            sessionState: session,
            powerState: MacOSPowerStateProvider(clock: clock),
            inputActivity: MacOSInputActivityProvider(session: session, screen: screen),
            lockController: MacOSLockController(screen: screen, clock: clock),
            wakeController: MacOSWakeController(),
            loginItem: SMAppServiceLoginItemController(),
            deviceStore: deviceStore,
            calibrationStore: calibrationStore,
            settingsStore: settingsStore,
            recorder: DiagnosticsRecorder(appVersion: appVersion),
            macIdentity: MacIdentity.current(),
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            appVersion: appVersion,
            nowUnixSeconds: { Int64(Date().timeIntervalSince1970) }
        )
    }

    /// The same graph with every adapter replaced by a Fake — architecture.md §3's
    /// `TestContainer`, as a factory rather than a subclass so there is exactly one container
    /// type and no chance of production behaviour diverging from what tests exercise.
    ///
    /// Every parameter has a default, so a test overrides only what it is about.
    public static func makeForTesting(
        clock: any MonotonicClock = FakeClock(),
        scanner: any BLEScanning = FakeScanner(),
        screenState: any ScreenStateProviding = FakeScreenStateProvider(),
        sessionState: any SessionStateProviding = FakeSessionStateProvider(),
        powerState: any PowerStateProviding = FakePowerStateProvider(),
        inputActivity: any InputActivityProviding = FakeInputActivityProvider(),
        lockController: any LockControlling = SpyLockController(),
        wakeController: any WakeControlling = SpyWakeController(),
        loginItem: any LoginItemControlling = FakeLoginItemController(),
        deviceStore: any DeviceStore = InMemoryDeviceStore(),
        calibrationStore: any CalibrationStore = InMemoryCalibrationStore(),
        settingsStore: any SettingsStore = InMemorySettingsStore(),
        recorder: DiagnosticsRecorder = DiagnosticsRecorder(appVersion: "test"),
        calibrationPolicy: CalibrationPolicy = CalibrationPolicy(),
        macIdentity: String? = "test-mac",
        osMajorVersion: Int = 26,
        appVersion: String = "test",
        nowUnixSeconds: @escaping @Sendable () -> Int64 = { 1_000_000 }
    ) -> AppContainer {
        AppContainer(
            clock: clock,
            scanner: scanner,
            screenState: screenState,
            sessionState: sessionState,
            powerState: powerState,
            inputActivity: inputActivity,
            lockController: lockController,
            wakeController: wakeController,
            loginItem: loginItem,
            deviceStore: deviceStore,
            calibrationStore: calibrationStore,
            settingsStore: settingsStore,
            recorder: recorder,
            calibrationPolicy: calibrationPolicy,
            macIdentity: macIdentity,
            osMajorVersion: osMajorVersion,
            appVersion: appVersion,
            nowUnixSeconds: nowUnixSeconds
        )
    }

    static let fallbackBundleIdentifier = "dev.threshold.app"

    static func bundleShortVersion() -> String {
        // "0.1.0" rather than "0.0.0": a bare `swift run` has no bundle, and a version string
        // that looks like a real release would be worse in a diagnostics export than one that
        // is obviously a development build.
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    // MARK: - Lifecycle

    /// Loads persisted state, arms scanning if there is a device to scan for, and starts the
    /// long-lived tasks.
    ///
    /// Store failures are collected into `AppModel.startupIssues` instead of throwing. A
    /// `settings.json` this build cannot read must not stop the app from launching, but it
    /// must also never be silently replaced with defaults — the user is told, and the file is
    /// left alone.
    public func start() {
        var issues: [String] = []
        if let deferredStartupIssue {
            issues.append(deferredStartupIssue)
            self.deferredStartupIssue = nil
        }

        var registry = DeviceRegistry()
        do {
            for record in try deviceStore.load() {
                registry = registry.adding(id: record.device, name: record.name)
            }
        } catch {
            issues.append(StoreErrorText.describe(error))
        }
        model.registry = registry

        do {
            calibrationRecords = try calibrationStore.load()
        } catch {
            issues.append(StoreErrorText.describe(error))
        }

        do {
            if let stored = try settingsStore.load() { model.settings = stored }
        } catch {
            issues.append(StoreErrorText.describe(error))
        }

        model.startupIssues = issues
        model.calibrationGate = currentGate()
        refreshLoginItemStatus()

        needsOnboarding = registry.isEmpty
        armScanning()

        sensorTask = Task { [weak self] in await self?.runSensorChannel() }
        diagnosticsTask = Task { [weak self] in await self?.runDiagnosticsPoll() }
    }

    /// Cancels every long-lived task and stops the scanner.
    ///
    /// Controller work already in flight is not cancelled: a lock that has been issued should
    /// finish (architecture.md §5.4).
    public func stop() {
        sensorTask?.cancel(); sensorTask = nil
        diagnosticsTask?.cancel(); diagnosticsTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        calibrationTask?.cancel(); calibrationTask = nil
        scanner.stopDiscovery()
        scanner.stopScanning()
    }

    /// Feeds the sensor axis until the Coordinator takes over this subscription.
    ///
    /// Also mirrors every status to `onboarding`, so the device-picker step can tell "still
    /// looking" apart from "Bluetooth just reported `.unauthorized`" instead of spinning
    /// forever (`OnboardingFlow.discoveryState`). Harmless when onboarding is `nil` or on a
    /// different step: `sensorStatusChanged` only ever updates its own state.
    private func runSensorChannel() async {
        for await status in scanner.sensorStates {
            model.sensorStatusChanged(status.value)
            onboarding?.sensorStatusChanged(status.value)
            await recorder.record(
                category: .bluetoothLifecycle,
                message: "sensor status \(status.value)",
                monotonicNanoseconds: status.at.nanoseconds
            )
        }
    }

    /// Polls the recorder at 1 Hz (ADR-007), so high-frequency events never touch the main actor.
    private func runDiagnosticsPoll() async {
        while !Task.isCancelled {
            model.diagnostics = await recorder.snapshot()
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    /// Scans for exactly the registered devices, or not at all when there are none.
    func armScanning() {
        scanner.startScanning(for: model.registry.deviceIDs)
    }

    // MARK: - Calibration gate

    /// Recomputes `CalibrationGate` for the current trusted device.
    ///
    /// A `nil` machine identity disarms rather than defaulting. Substituting an empty string
    /// would compare unequal to any stored identity and land on `macMismatch`, which is the
    /// right *outcome* but the wrong *reason*; saying so explicitly keeps the reason honest,
    /// and both paths fail closed (security.md §2 rule 4).
    public func currentGate() -> CalibrationGate {
        guard let device = model.registry.devices.first?.id else { return .notArmed(.noProfile) }
        guard let macIdentity else { return .notArmed(.macMismatch) }
        return CalibrationValidator.gate(
            record: calibrationRecords.first { $0.device == device },
            device: device,
            macIdentity: macIdentity,
            osMajorVersion: osMajorVersion,
            nowUnixSeconds: nowUnixSeconds(),
            policy: calibrationPolicy
        )
    }

    public var calibrationEnvironment: CalibrationEnvironment {
        CalibrationEnvironment(
            macIdentity: macIdentity,
            osMajorVersion: osMajorVersion,
            appVersion: appVersion,
            nowUnixSeconds: nowUnixSeconds()
        )
    }

    // MARK: - Settings

    /// Applies a change to `PolicySettings`, persists it, and reports a save failure.
    ///
    /// The in-memory value is updated even when the write fails, because refusing the toggle
    /// the user just moved is more confusing than a switch that works now and warns that it
    /// will not survive a relaunch.
    public func updateSettings(_ transform: (inout PolicySettings) -> Void) {
        var settings = model.settings
        transform(&settings)
        guard settings != model.settings else { return }
        model.settings = settings
        do {
            try settingsStore.save(settings)
        } catch {
            model.startupIssues.append(StoreErrorText.describe(error))
        }
    }

    public func setAutoLock(_ enabled: Bool) { updateSettings { $0.autoLock = enabled } }
    public func setWakeOnReturn(_ enabled: Bool) { updateSettings { $0.wakeOnReturn = enabled } }
    public func setLockOnDepartureThenSilent(_ enabled: Bool) {
        updateSettings { $0.lockOnDepartureThenSilent = enabled }
    }
    public func setSilenceLock(_ policy: SilenceLockPolicy) { updateSettings { $0.silenceLock = policy } }

    // MARK: - Devices

    /// Adds or renames a trusted device and rearms scanning around the new set.
    public func registerDevice(_ device: RegisteredDevice) throws {
        let registry = model.registry.adding(device)
        try persist(registry: registry)
        armScanning()
    }

    public func renameDevice(_ id: DeviceID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try persist(registry: model.registry.renaming(id, to: trimmed))
    }

    /// Removes a trusted device **and** its calibration.
    ///
    /// The calibration goes with it deliberately. A profile is a measurement of one device's
    /// signal in one room on one Mac; keeping it after the device is gone means that
    /// re-adding a device with the same identifier later would silently arm automation on a
    /// months-old measurement the user never re-took.
    public func removeDevice(_ id: DeviceID) throws {
        try persist(registry: model.registry.removing(id))
        let remaining = calibrationRecords.filter { $0.device != id }
        if remaining.count != calibrationRecords.count {
            let previous = calibrationRecords
            calibrationRecords = remaining
            do {
                try calibrationStore.save(remaining)
            } catch {
                calibrationRecords = previous
                model.calibrationGate = currentGate()
                throw error
            }
        }
        model.calibrationGate = currentGate()
        needsOnboarding = model.registry.isEmpty
        armScanning()
    }

    /// Discards every stored calibration, leaving trusted devices registered.
    public func resetCalibration() throws {
        let previous = calibrationRecords
        calibrationRecords = []
        do {
            try calibrationStore.save([])
        } catch {
            calibrationRecords = previous
            throw error
        }
        model.calibrationGate = currentGate()
    }

    private func persist(registry: DeviceRegistry) throws {
        let records = registry.devices.map { DeviceRecord(device: $0.id, name: $0.name) }
        try deviceStore.save(records)
        model.registry = registry
        model.calibrationGate = currentGate()
    }

    // MARK: - Login item

    public func refreshLoginItemStatus() {
        model.loginItemStatus = .known(loginItem.status)
    }

    /// Optional permission, requested only at the end of onboarding or from Settings
    /// (system-integration.md §6: request only when the feature requires it).
    public func setLoginItemEnabled(_ enabled: Bool) throws {
        defer { refreshLoginItemStatus() }
        if enabled {
            try loginItem.register()
        } else {
            try loginItem.unregister()
        }
    }

    // MARK: - Diagnostics export

    /// De-identified export bytes, or a throw.
    ///
    /// Nothing is written to disk here on purpose: `DiagnosticsRecorder.export()` fails closed
    /// on an anonymity violation, and the caller must not have a half-written file to clean up
    /// when it does. The save panel only sees bytes that already passed the check.
    public func exportDiagnostics() async throws -> Data {
        try await recorder.export()
    }
}
