import ThresholdAppKit
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem

// Stable spellings for the values this tool prints.
//
// Written out by hand rather than taken from `String(describing:)` so the transcript format
// is pinned here: a run captured today has to stay comparable with one captured after a
// Domain enum grows a case, and `String(describing:)` would silently change under it.
//
// `PresenceState`, `SensorHealth` and friends already carry a `label` in the Domain
// (`StateDescriptions.swift`); those are used as-is rather than re-spelled here.

extension ScreenState {
    var smokeLabel: String {
        switch self {
        case .unlocked: "unlocked"
        case .locked: "locked"
        case .unknown: "unknown"
        }
    }
}

extension SessionState {
    var smokeLabel: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .unknown: "unknown"
        }
    }
}

extension PowerState {
    var smokeLabel: String {
        switch self {
        case .awake: "awake"
        case .displayAsleep: "displayAsleep"
        case .systemAsleep: "systemAsleep"
        case .unknown: "unknown"
        }
    }
}

extension NotArmedReason {
    var smokeLabel: String {
        switch self {
        case .noProfile: "noProfile"
        case .deviceMismatch: "deviceMismatch"
        case .macMismatch: "macMismatch"
        case .needsRevalidation(let osMajorChanged): "needsRevalidation(osMajorChanged: \(osMajorChanged))"
        case .driftExceeded: "driftExceeded"
        case .invalid(let failure): "invalid(\(failure))"
        }
    }
}

extension CalibrationGate {
    var smokeLabel: String {
        switch self {
        case .armed: "armed"
        case .notArmed(let reason): "notArmed(\(reason.smokeLabel))"
        }
    }
}

extension ProtectionStatus {
    /// The status case, as the menu's first line branches on it.
    var smokeLabel: String {
        switch self {
        case .initializing: "initializing"
        case .active: "active"
        case .paused: "paused"
        case .notArmed: "notArmed"
        }
    }

    /// The plain-language half the user reads, or `nil` for the two cases that have none.
    var smokeReason: String? {
        switch self {
        case .initializing, .active: nil
        case .paused(let reason), .notArmed(let reason): reason
        }
    }
}

extension LoginItemStatus {
    var smokeLabel: String {
        switch self {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        case .unknown: "unknown"
        }
    }
}

extension LoginItemDisplay {
    var smokeLabel: String {
        switch self {
        case .unknown: "notQueried"
        case .known(let status): status.smokeLabel
        }
    }
}

extension OnboardingFlow.DiscoveryState {
    var smokeLabel: String {
        switch self {
        case .idle: "idle"
        case .scanning: "scanning"
        case .found: "found"
        case .blocked(let reason, let canOpenSettings):
            "blocked(\(reason.rawValue), canOpenSettings: \(canOpenSettings))"
        }
    }
}

extension DiagnosticEvent.Category {
    /// The `CoordinatorEvent` case this category comes from, or `nil` for a category no
    /// Coordinator event produces.
    ///
    /// `DiagnosticsBridge` is a total, one-to-one mapping from `CoordinatorEvent` onto these
    /// categories, so reversing it recovers the event kinds exactly. That is the only way this
    /// tool can count events without stealing them: `Coordinator.events` is an `AsyncStream`
    /// with exactly one iterator — the container's — and a second `for await` would take half
    /// the events away from the app under test.
    var coordinatorEventCase: String? {
        switch self {
        case .presenceScore: "snapshotUpdated"
        case .transition: "transition"
        case .policyEvaluation: "policyEvaluated"
        case .actionDispatched: "actionDispatched"
        case .actionOutcome: "actionAcknowledged"
        case .systemLifecycle: "lifecycle"
        case .bluetoothLifecycle: "sensorRestart"
        case .bleObservation, .signalEstimate, .calibration, .securityDenial: nil
        }
    }
}
