import Foundation
import Observation
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// What onboarding needs the rest of the app to do for it.
///
/// The flow owns *which step the user is on* and nothing else: no scanner, no store, no
/// registry write. That separation is what makes every rule below assertable in a unit test
/// with a spy, and it keeps the composition-root rule intact — `AppContainer` is still the
/// only object that touches a concrete adapter.
@MainActor
public protocol OnboardingActions: AnyObject {
    /// Creates the `CBCentralManager` if it does not exist yet, which is what raises the
    /// system Bluetooth prompt. Called only from step 1's explicit button, never at launch
    /// (architecture.md §5.4).
    func startDiscovery()
    func stopDiscovery()
    /// Persists the device and rearms scanning around it.
    func registerDevice(_ device: RegisteredDevice) throws
    /// Onboarding is over; the window may close.
    func completeOnboarding()
}

/// The first-launch state machine: permission → pick a device → calibrate → login item.
///
/// Ordering follows system-integration.md §6: Bluetooth is required and is asked for first,
/// with an explanation on screen before the system prompt appears; the Login Item is optional
/// and is asked for last, after the app has done something worth launching at login for.
/// Accessibility is never requested anywhere in this flow (ADR-001).
@MainActor
@Observable
public final class OnboardingFlow {

    public enum Step: Sendable, Equatable, CaseIterable {
        /// Explain why Bluetooth is needed, then let the user trigger the system prompt.
        case bluetooth
        /// Live discovery list.
        case pickDevice
        /// Near/far calibration; may be skipped, leaving the gate unarmed.
        case calibrate
        /// Optional launch-at-login.
        case loginItem
        case finished
    }

    /// What the device-picker step should show, derived from the scanner's `sensorStates`
    /// channel while discovery is running.
    ///
    /// This exists because the step's own spinner ("Looking for devices…") cannot tell the
    /// difference between "no advertisements yet" and "no advertisements ever, because
    /// CoreBluetooth just reported `.unauthorized`" — and left alone, the second one renders
    /// as the first forever. `blocked` is that distinction made visible, with the same reason
    /// and remedy the main menu's `DegradedBanner` already shows for a degraded sensor.
    public enum DiscoveryState: Sendable, Equatable {
        /// Not currently scanning.
        case idle
        /// Scanning, the sensor is healthy or between states, and no device has appeared yet.
        case scanning
        /// The scanner cannot currently supply advertisements at all.
        case blocked(reason: UnavailableReason, canOpenSettings: Bool)
        /// Scanning, the sensor is healthy, and at least one device has appeared.
        case found
    }

    public private(set) var step: Step = .bluetooth
    public private(set) var table = DiscoveryTable()
    public private(set) var isScanning = false
    public private(set) var selection: DeviceID?
    /// Whether calibration ran to a saved profile, as opposed to being skipped.
    public private(set) var didCalibrate = false
    public private(set) var errorMessage: String?
    /// The most recent status fed in by `sensorStatusChanged`, `nil` until the first one
    /// arrives for this discovery session.
    public private(set) var lastSensorStatus: SensorStatus?

    /// The name the user is giving the device. Pre-filled from the advertisement when there
    /// is one, but always editable: the advertised name is a hint, and `RegisteredDevice`
    /// deliberately stores a user-supplied name (reading the system Bluetooth database to get
    /// a model name is prohibited by ADR-004).
    public var deviceName: String = ""

    /// Show identifiers that never advertised a name. Off by default; see `SupportedDevices.noiseNote`.
    public var showEveryDevice = false

    /// Weak, and deliberately not `unowned`: the container owns the flow, so a strong link
    /// back would be a cycle, and an `unowned` one would trap if a window outlived the
    /// container during teardown. A flow whose actions have gone is inert, which is the right
    /// behaviour for a screen that is already on its way out.
    private weak var actions: (any OnboardingActions)?

    public init(actions: any OnboardingActions) {
        self.actions = actions
    }

    // MARK: - Derived

    public var rows: [DiscoveryRow] { table.rows(namedOnly: !showEveryDevice) }

    /// Devices hidden by the name filter, so the UI can say how many rather than pretend the
    /// room is quiet.
    public var hiddenDeviceCount: Int { table.totalSeen - rows.count }

    public var trimmedDeviceName: String {
        deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A device may be registered only once it has both an identifier and a name the user
    /// typed. An empty name is rejected rather than defaulted, because "Unnamed device" in the
    /// menu bar tells a user nothing about what is protecting their Mac.
    public var canRegisterDevice: Bool {
        selection != nil && !trimmedDeviceName.isEmpty
    }

    /// See `DiscoveryState`. Not scanning at all reads as `.idle` regardless of the last
    /// status this instance ever saw, so leaving the picker and coming back never shows a
    /// banner left over from a previous visit.
    public var discoveryState: DiscoveryState {
        guard isScanning else { return .idle }
        switch lastSensorStatus {
        case nil, .available, .degraded:
            return rows.isEmpty ? .scanning : .found
        case .unavailable(let reason):
            return .blocked(reason: reason, canOpenSettings: BluetoothRemedy(unavailableReason: reason) != nil)
        }
    }

    // MARK: - Transitions

    /// Step 1 → 2. This is the call that may raise the system Bluetooth permission prompt.
    public func startScanning() {
        guard step == .bluetooth || step == .pickDevice else { return }
        errorMessage = nil
        table.reset()
        lastSensorStatus = nil
        isScanning = true
        step = .pickDevice
        actions?.startDiscovery()
    }

    public func discovered(_ device: DiscoveredDevice) {
        guard isScanning else { return }
        table.ingest(device)
    }

    /// Fed by the container from the scanner's `sensorStates` channel while onboarding is
    /// alive. Only changes `discoveryState`; presence/selection are untouched because this can
    /// arrive on any step, not only `.pickDevice`.
    ///
    /// A recovery from `.blocked` while still scanning asks for a fresh discovery session
    /// rather than trusting that the CoreBluetooth session already running repairs itself —
    /// cheap insurance against a session CoreBluetooth silently dropped while the radio was
    /// off or unauthorized.
    public func sensorStatusChanged(_ status: SensorStatus) {
        let wasBlocked: Bool
        if case .unavailable = lastSensorStatus { wasBlocked = true } else { wasBlocked = false }
        lastSensorStatus = status
        if wasBlocked, status == .available, isScanning {
            actions?.startDiscovery()
        }
    }

    public func select(_ id: DeviceID) {
        selection = id
        // Pre-fill only when the user has not typed anything, so switching rows never discards
        // a name they were in the middle of writing.
        if trimmedDeviceName.isEmpty, let row = rows.first(where: { $0.id == id }), let advertised = row.advertisedName {
            deviceName = advertised
        }
    }

    /// Step 2 → 3. Stops discovery, persists the device, and moves to calibration.
    ///
    /// A store failure keeps the user on this step with the reason shown. Advancing anyway
    /// would leave them calibrating a device that was never saved.
    public func registerSelectedDevice() {
        guard let selection, canRegisterDevice else { return }
        errorMessage = nil
        do {
            try actions?.registerDevice(RegisteredDevice(id: selection, name: trimmedDeviceName))
        } catch {
            errorMessage = "Your device could not be saved: \(StoreErrorText.describe(error))"
            return
        }
        stopScanning()
        step = .calibrate
    }

    /// Enters the flow at the calibration step, for a user who already has a trusted device
    /// and picked "Calibrate…" from the menu. Discovery is not started, so no permission
    /// prompt and no scan happen on this path.
    public func jumpToCalibration() {
        stopScanning()
        errorMessage = nil
        step = .calibrate
    }

    /// Step 3 → 4 after a profile was saved.
    public func calibrationSucceeded() {
        guard step == .calibrate else { return }
        didCalibrate = true
        step = .loginItem
    }

    /// Step 3 → 4 without a profile.
    ///
    /// Allowed on purpose. The alternative — trapping a user in calibration until the room
    /// cooperates — is worse than an app that runs with `CalibrationGate.notArmed` and says so
    /// on its first line. Automation stays off until calibration succeeds (security.md §2
    /// rule 4), so skipping is safe; it is only unhelpful.
    public func skipCalibration() {
        guard step == .calibrate else { return }
        didCalibrate = false
        step = .loginItem
    }

    /// Step 4 → done.
    public func finish() {
        stopScanning()
        step = .finished
        actions?.completeOnboarding()
    }

    /// Leaves onboarding from any step. Whatever was already saved stays saved.
    public func cancel() {
        stopScanning()
        step = .finished
        actions?.completeOnboarding()
    }

    public func reportError(_ message: String) { errorMessage = message }
    public func clearError() { errorMessage = nil }

    private func stopScanning() {
        guard isScanning else { return }
        isScanning = false
        actions?.stopDiscovery()
    }
}
