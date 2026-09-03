import Foundation
import Observation
import ThresholdBluetooth
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem

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
/// **Coordinator.** `start()` builds the two Domain engines and hands them to the `Coordinator`
/// actor (architecture.md §5) along with the production adapters. From then on this class does
/// not touch the monitoring pipeline at all: it *sends* `CoordinatorInput` when the user
/// changes something the Coordinator caches, and it *receives* `CoordinatorEvent` and mirrors
/// it into `AppModel`. Presence, evidence, sensor health, transitions and rationale all arrive
/// that way; nothing here recomputes them. See `AppContainer+Wiring.swift` for the two
/// directions and `AppContainer+Lifecycle.swift` for the task handles.
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

    /// The scanner as the Coordinator and the calibration flow see it.
    ///
    /// `scanner.observations` is single-consumer, and both of those need it; the tee is what
    /// stops them racing for the same advertisements. Every other call goes straight through
    /// to `scanner`, so this is not a second scanning policy.
    let tee: ObservationTee

    // MARK: - Runtime

    /// `nil` until `start()`, and again after `stop()`.
    public internal(set) var coordinator: Coordinator?

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

    // MARK: - Long-lived tasks (architecture.md §3: every handle is owned here)

    /// Starts the Coordinator, then pumps `coordinatorInputs` into it.
    ///
    /// One task rather than a `Task` per call is what makes ordering decidable: `start()`
    /// happens before every input, and a `.calibrationChanged` sent before a `.devicesChanged`
    /// is seen in that order by the actor, which is the order the engine has to be rebuilt in.
    var coordinatorTask: Task<Void, Never>?
    /// Drains `Coordinator.events` into `AppModel` *and* `DiagnosticsBridge`.
    ///
    /// One subscription, two consumers. `events` is an `AsyncStream`, which hands each element
    /// to exactly one iterator, so a second `for await` would steal events from the first and
    /// the diagnostics trail would silently lose half of itself.
    var eventsTask: Task<Void, Never>?
    var diagnosticsTask: Task<Void, Never>?
    var discoveryTask: Task<Void, Never>?
    var calibrationTask: Task<Void, Never>?

    var coordinatorInputs: AsyncStream<CoordinatorInput>.Continuation?

    /// The sensor health last forwarded to `onboarding`, so an unchanged axis inside a changed
    /// snapshot does not re-notify a flow that reacts to recovery by restarting discovery.
    var lastForwardedSensorHealth: SensorHealth?

    /// A launch problem discovered before `start()` had somewhere to report it.
    var deferredStartupIssue: String?

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
        self.tee = ObservationTee(scanner)
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
    ///
    /// - Parameter storageDirectory: where the three JSON stores live. `nil` — the app's own
    ///   path — resolves `~/Library/Application Support/<bundle id>/` (system-integration.md §3).
    ///   It is a parameter only so a headless verification tool (`Tools/app-smoke`) can point the
    ///   *production* graph at a throwaway directory instead of the user's real one. Nothing in
    ///   the shipping app passes it, and it does not weaken the composition-root rule: this is
    ///   still the only place a concrete store is constructed.
    public static func live(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            appVersion: String? = nil,
                            storageDirectory: URL? = nil) throws -> AppContainer {
        let identifier = bundleIdentifier ?? Self.fallbackBundleIdentifier
        let directory = try storageDirectory ?? ApplicationSupportDirectory.url(bundleIdentifier: identifier)
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
                                 appVersion: String? = nil,
                                 storageDirectory: URL? = nil) -> AppContainer {
        do {
            return try live(bundleIdentifier: bundleIdentifier,
                            appVersion: appVersion,
                            storageDirectory: storageDirectory)
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
            // `MonotonicBLEClock` lives in ThresholdRuntime because that is the lowest layer
            // allowed to see both Bluetooth and System (architecture.md §2.2): Bluetooth
            // declares the narrow `BLEClock` protocol, and someone above both supplies it.
            // One clock, so no two components can disagree about what "now" is.
            scanner: CoreBluetoothScanner(clock: MonotonicBLEClock(clock)),
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
