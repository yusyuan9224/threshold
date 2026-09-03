import Observation
import ThresholdBluetooth
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem

/// What the menu's first line says, and therefore what the user believes is protecting them.
///
/// The four cases are not decoration: they are the visible half of `security.md` §2. Rule 2
/// says a non-healthy sensor must stop producing actions **and** the UI must show that
/// automatic protection is paused; rule 4 says an unarmed calibration disarms Auto Lock and
/// Wake. `paused` and `notArmed` are what those two rules look like on screen, and keeping
/// them apart matters because they need different fixes: one is "turn Bluetooth back on",
/// the other is "walk through calibration".
///
/// `initializing` exists rather than folding into `paused` because the first seconds after
/// launch are not a fault, and telling a user protection is "paused" while the app is simply
/// starting up trains them to ignore the word.
///
/// The reason is a `String` because it is display text and nothing branches on it. Anything
/// the UI must *act* on — offering the Bluetooth settings button, say — is derived from the
/// underlying `SensorHealth` instead (`AppModel.bluetoothRemedy`), so no view ever parses
/// a sentence back into a decision.
public enum ProtectionStatus: Sendable, Equatable {
    case initializing
    case active
    case paused(reason: String)
    case notArmed(reason: String)
}

/// The one remedy the app can offer for a Bluetooth problem: send the user to the right pane.
///
/// `nil` when there is nothing actionable — a powered-off radio is fixed in Control Centre or
/// System Settings, an unauthorised app is fixed in Privacy & Security, and an unsupported
/// Mac cannot be fixed at all.
public enum BluetoothRemedy: Sendable, Equatable {
    /// Deep link to System Settings › Privacy & Security › Bluetooth.
    case openPrivacySettings
    /// Deep link to System Settings › Bluetooth (turn the radio back on).
    case openBluetoothSettings

    /// The one place `UnavailableReason` is mapped onto a remedy, so `AppModel.bluetoothRemedy`
    /// and `OnboardingFlow.DiscoveryState` (which sees the same reason before a `SensorHealth`
    /// exists) cannot drift apart.
    public init?(unavailableReason reason: UnavailableReason) {
        switch reason {
        case .unauthorized: self = .openPrivacySettings
        case .poweredOff: self = .openBluetoothSettings
        // Nothing in System Settings fixes a Mac without usable Bluetooth, and a scanner that
        // failed is the app's problem to recover from, not the user's to configure.
        case .unsupported, .scannerFailed: return nil
        }
    }
}

/// Everything the UI renders, in one `@Observable` object owned by `AppContainer`.
///
/// It is a *sink*, not a source: presence, evidence and sensor health are produced by the
/// engine behind the `Coordinator` actor and arrive through `AppEventSink`. The model never
/// computes a Domain fact of its own — `protectionStatus` is the one derived value here, and
/// it is a pure function of fields that were handed to it.
///
/// Every field below is written by exactly one `CoordinatorEvent`, and until the first one
/// arrives the model says so honestly: presence reads as "Still working out where you are"
/// rather than defaulting to something more comfortable.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Engine-owned state (written only through `AppEventSink`)

    public private(set) var presence: PresenceState = .unknown(.initial)
    public private(set) var evidence: PresenceEvidence = .none
    public private(set) var sensorHealth: SensorHealth = .initializing
    public private(set) var lastTransition: ProximityTransition?
    public private(set) var lastRationale: [PolicyRationale] = []

    // MARK: - Container-owned state

    public internal(set) var registry: DeviceRegistry
    public internal(set) var calibrationGate: CalibrationGate
    public internal(set) var settings: PolicySettings
    public internal(set) var loginItemStatus: LoginItemDisplay = .unknown

    /// Polled at 1 Hz from the `DiagnosticsRecorder` actor (ADR-007). `nil` before the first poll.
    public internal(set) var diagnostics: DiagnosticsSnapshot?

    /// Non-fatal problems from startup — a store that would not load, a login-item query that
    /// failed. Surfaced rather than swallowed: a user whose trusted device silently vanished
    /// because `devices.json` failed to decode deserves to be told (`StoreError` is explicitly
    /// never repaired silently).
    public internal(set) var startupIssues: [String] = []

    public init(
        registry: DeviceRegistry = DeviceRegistry(),
        calibrationGate: CalibrationGate = .notArmed(.noProfile),
        settings: PolicySettings = PolicySettings()
    ) {
        self.registry = registry
        self.calibrationGate = calibrationGate
        self.settings = settings
    }

    // MARK: - Derived

    /// The name of the first trusted device, or `nil` when none is registered.
    ///
    /// MVP fuses a single device (proximity-domain.md §3), so the menu shows one name; the
    /// registry stays a list because the data shape is multi-device from day one.
    public var trustedDeviceName: String? { registry.devices.first?.name }

    public var hasTrustedDevice: Bool { !registry.isEmpty }

    /// The status line, derived fail-closed and in the order the rules are written.
    ///
    /// Order is the whole design. Registration comes first because an app with no trusted
    /// device is not paused, it is not set up. Sensor health comes before calibration because
    /// rule 2 stops actions regardless of the gate, so reporting "not armed: calibrate" while
    /// Bluetooth is off would send the user to do 40 seconds of calibration that cannot
    /// possibly help. Settings come last because a user who turned both switches off knows
    /// why nothing is happening — it is the least alarming reason, so it must not mask a real
    /// one above it.
    public var protectionStatus: ProtectionStatus {
        guard hasTrustedDevice else {
            return .notArmed(reason: "set up a trusted device")
        }
        if case .initializing = sensorHealth {
            return .initializing
        }
        guard sensorHealth == .healthy else {
            return .paused(reason: PlainLanguage.sensorHealth(sensorHealth))
        }
        if case .notArmed(let reason) = calibrationGate {
            return .notArmed(reason: PlainLanguage.notArmed(reason))
        }
        guard settings.autoLock || settings.wakeOnReturn else {
            return .paused(reason: "both automatic actions are turned off in Settings")
        }
        return .active
    }

    /// The banner required by `security.md` §2 rule 2, or `nil` when the sensor is fine.
    public var degradedBanner: String? { PlainLanguage.degradedBanner(sensorHealth) }

    /// Where to send the user when Bluetooth is the problem.
    public var bluetoothRemedy: BluetoothRemedy? {
        guard case .unavailable(let reason) = sensorHealth else { return nil }
        return BluetoothRemedy(unavailableReason: reason)
    }

    /// Plain-language presence and its provenance, for the two lines under the status.
    public var presenceDescription: String { PlainLanguage.presence(presence) }
    public var evidenceDescription: String { PlainLanguage.evidence(evidence) }

    /// The last thing that actually changed, in plain language. `nil` until something has.
    ///
    /// Shown because a status line alone cannot answer "why does it think that". A user who
    /// disagrees with the current belief needs to see the moment it formed before they can
    /// tell whether the app is wrong or the room is.
    public var lastChangeDescription: String? {
        lastTransition.map(PlainLanguage.transition)
    }

    /// Why the last policy evaluation did or did not act. `nil` before the first one.
    ///
    /// The rationale is the audit trail made visible (ADR-007). "Not locking: Bluetooth is not
    /// reporting" is the difference between a user trusting the app and a user quietly
    /// assuming it is broken.
    public var lastDecisionDescription: String? {
        PlainLanguage.decision(lastRationale)
    }
}

// MARK: - AppEventSink

/// A display-side mirror of `LoginItemStatus`.
///
/// `ThresholdAppKit` could use `LoginItemStatus` directly, and does everywhere it talks to the
/// controller. This separate enum exists only so `AppModel` can hold "not asked yet" as a
/// distinct value from any state macOS actually reports.
public enum LoginItemDisplay: Sendable, Equatable {
    case unknown
    case known(LoginItemStatus)
}

/// The receiving end of `Coordinator.events`, named after what the App layer needs rather
/// than after the actor that supplies it.
///
/// The shape mirrors architecture.md §5.1's event list, so `AppContainer.apply(_:)` stays a
/// translation and not a second place where behaviour is decided. There is deliberately no
/// sensor-only entry point: sensor health arrives folded into `snapshotUpdated`, which is the
/// engine's settled view of all three axes at once, and a separate channel for it could put
/// the menu's status line and its presence line at odds with each other.
@MainActor
public protocol AppEventSink: AnyObject {
    func snapshotUpdated(_ snapshot: ProximitySnapshot)
    func transitionOccurred(_ transition: ProximityTransition)
    func policyEvaluated(rationale: [PolicyRationale])
}

extension AppModel: AppEventSink {

    public func snapshotUpdated(_ snapshot: ProximitySnapshot) {
        presence = snapshot.presence
        evidence = snapshot.evidence
        sensorHealth = snapshot.sensor
    }

    public func transitionOccurred(_ transition: ProximityTransition) {
        lastTransition = transition
    }

    public func policyEvaluated(rationale: [PolicyRationale]) {
        lastRationale = rationale
    }

}
