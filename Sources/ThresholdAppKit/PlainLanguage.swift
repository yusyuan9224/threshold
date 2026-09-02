import ThresholdDomain
import ThresholdSystem

/// Every user-facing sentence the App layer produces, in one place.
///
/// Two reasons it is a namespace of pure functions rather than strings scattered through
/// views. First, these sentences are the product's honesty surface: `security.md` §2 rule 2
/// requires the UI to *say* that automatic protection is paused, and ADR-008 requires the
/// difference between "nobody is here" and "we stopped being able to tell" to survive all
/// the way to the screen. Wording that carries that distinction has to be reviewable in one
/// file. Second, a pure function of a Domain value is directly testable, which a `Text`
/// inside a view body is not.
///
/// English only for now; there is no localisation infrastructure yet and pretending
/// otherwise with a `.strings` file nobody translates would be worse than not having one.
public enum PlainLanguage {

    // MARK: - Presence

    /// What the app currently believes about the user, in the user's own terms.
    ///
    /// `unknown` never reads as "away". That is ADR-008 in one sentence: the absence of
    /// evidence is not evidence of absence, and a status line that renders "no signal" as
    /// "you are away" is the exact mistake the product exists to avoid.
    public static func presence(_ state: PresenceState) -> String {
        switch state {
        case .present: return "You are at your Mac"
        case .departing: return "You seem to be moving away"
        case .away: return "You are away"
        case .unknown(let reason):
            switch reason {
            case .initial: return "Still working out where you are"
            case .evidenceExpired: return "Not sure — your device has gone quiet"
            case .reset(let cause): return "Starting over after \(resetCause(cause))"
            case .sensorRestored: return "Starting over now that Bluetooth is back"
            }
        }
    }

    public static func resetCause(_ reason: ResetReason) -> String {
        switch reason {
        case .systemWake: return "waking up"
        case .bluetoothReset: return "a Bluetooth reset"
        case .sessionChanged: return "a login session change"
        case .devicesChanged: return "a device change"
        }
    }

    /// Where the current belief came from. Shown next to the presence line because "we can
    /// see your phone" and "your phone went quiet after you walked off" justify very
    /// different amounts of trust.
    public static func evidence(_ evidence: PresenceEvidence) -> String {
        switch evidence {
        case .none: return "No signal to go on yet"
        case .measuredNear: return "Your device's signal is strong"
        case .measuredFar: return "Your device's signal has faded"
        case .departureThenSilent: return "Your device faded, then went silent"
        }
    }

    // MARK: - Sensor health

    public static func sensorHealth(_ health: SensorHealth) -> String {
        switch health {
        case .initializing: return "Starting Bluetooth"
        case .healthy: return "Bluetooth is working"
        case .degraded(let reason):
            switch reason {
            case .resetting: return "Bluetooth is restarting"
            case .scanInterrupted: return "Bluetooth scanning was interrupted"
            }
        case .unavailable(let reason): return unavailable(reason)
        }
    }

    public static func unavailable(_ reason: UnavailableReason) -> String {
        switch reason {
        case .poweredOff: return "Bluetooth is turned off"
        case .unauthorized: return "Threshold is not allowed to use Bluetooth"
        case .unsupported: return "This Mac has no usable Bluetooth"
        case .scannerFailed: return "Bluetooth scanning stopped working"
        }
    }

    /// The banner sentence required by `security.md` §2 rule 2, plus the specific cause.
    public static func degradedBanner(_ health: SensorHealth) -> String? {
        guard health != .healthy else { return nil }
        if case .initializing = health { return nil }
        return "Bluetooth unavailable — automatic protection is paused. \(sensorHealth(health))."
    }

    // MARK: - Calibration gate

    public static func notArmed(_ reason: NotArmedReason) -> String {
        switch reason {
        case .noProfile: return "Calibrate your device to turn on automatic protection"
        case .deviceMismatch: return "Your calibration was measured for a different device"
        case .macMismatch: return "Your calibration was measured on a different Mac"
        case .needsRevalidation(let osMajorChanged):
            return osMajorChanged
                ? "macOS was upgraded — calibrate again to be sure"
                : "Your calibration is old enough to be worth redoing"
        case .driftExceeded: return "Signal conditions have changed — calibrate again"
        case .invalid(let failure): return calibrationFailure(failure)
        }
    }

    /// Failure text is phrased as the next thing to try, not as a diagnosis. `overlap` in
    /// particular is a room problem, not a user error: the two spots were too alike for any
    /// threshold to separate them.
    public static func calibrationFailure(_ failure: CalibrationFailure) -> String {
        switch failure {
        case .insufficientSamples(let phase):
            return "Not enough readings during the \(phaseName(phase)) step — stay put a little longer"
        case .tooNoisy(let phase):
            return "The signal jumped around too much during the \(phaseName(phase)) step — try again away from other electronics"
        case .overlap:
            return "The two spots gave signals too similar to tell apart — try a farther spot for the second step"
        }
    }

    public static func phaseName(_ phase: CalibrationPhase) -> String {
        switch phase {
        case .near: return "at your desk"
        case .far: return "away from your desk"
        }
    }

    public static func calibrationError(_ error: CalibrationFlowError) -> String {
        switch error {
        case .measurement(let failure): return calibrationFailure(failure)
        case .machineIdentityUnavailable:
            // Refusing is the honest outcome: a calibration with a synthetic machine identity
            // would compare equal on every Mac and quietly defeat `NotArmedReason.macMismatch`.
            return "This Mac would not identify itself, so the calibration cannot be saved safely"
        case .saveFailed(let detail): return "The calibration could not be saved: \(detail)"
        }
    }

    // MARK: - Protection status

    /// The single line at the top of the menu.
    public static func protectionStatus(_ status: ProtectionStatus) -> String {
        switch status {
        case .initializing: return "Sensor initializing"
        case .active: return "Active"
        case .paused(let reason): return "Paused: \(reason)"
        case .notArmed(let reason): return "Not armed: \(reason)"
        }
    }

    // MARK: - Login item

    public static func loginItem(_ status: LoginItemStatus) -> String {
        switch status {
        case .enabled: return "Threshold opens at login"
        case .notRegistered: return "Threshold does not open at login"
        case .requiresApproval: return "Approve Threshold in System Settings › General › Login Items"
        case .notFound: return "macOS cannot find this copy of Threshold — move it to Applications and try again"
        case .unknown: return "macOS reported a login-item state Threshold does not recognise"
        }
    }
}
