import Observation
import ThresholdDomain

/// Why a calibration run did not produce a saved profile.
///
/// Three kinds, kept apart because they are three different conversations with the user.
/// `measurement` is the Domain's verdict on the samples and is repairable by trying again
/// somewhere else. `machineIdentityUnavailable` is a refusal: without an `IOPlatformUUID`
/// there is no honest value for `CalibrationRecord.macIdentity`, and a synthetic one would
/// compare equal on every Mac, quietly defeating the `macMismatch` check that stops a profile
/// measured on one machine from arming automation on another (security.md §2 rule 4).
/// `saveFailed` is a storage problem that has nothing to do with the room.
public enum CalibrationFlowError: Error, Sendable, Equatable {
    case measurement(CalibrationFailure)
    case machineIdentityUnavailable
    case saveFailed(String)
}

/// Everything a `CalibrationRecord` needs that is not a measurement.
///
/// Passed in at `finish()` rather than read inside the flow, so the whole state machine stays
/// free of Foundation, IOKit and the process environment, and a test can pin every field.
public struct CalibrationEnvironment: Sendable, Equatable {
    /// `MacIdentity.current()`. `nil` is a real possibility and is treated as a refusal.
    public let macIdentity: String?
    public let osMajorVersion: Int
    public let appVersion: String
    /// Wall clock, used only for `createdAtUnixSeconds` — display and optional age checks.
    public let nowUnixSeconds: Int64

    public init(macIdentity: String?, osMajorVersion: Int, appVersion: String, nowUnixSeconds: Int64) {
        self.macIdentity = macIdentity
        self.osMajorVersion = osMajorVersion
        self.appVersion = appVersion
        self.nowUnixSeconds = nowUnixSeconds
    }
}

/// The two-phase calibration run, as a state machine over a `CalibrationSession`.
///
/// The flow adds exactly two things to the Domain session: which phase samples are currently
/// being filed under, and enough progress arithmetic to drive a progress bar. Every verdict —
/// too few samples, too noisy, overlapping — comes from `CalibrationSession.finish()`. That
/// division matters: a UI that decided for itself when a phase was "good enough" would be a
/// second, untested copy of the §7.2 rules.
///
/// Like the session, it never reads a clock. Samples arrive as `BLEObservation`s carrying the
/// `MonotonicInstant` the scanner stamped them with at the boundary (ADR-003).
@MainActor
@Observable
public final class CalibrationFlow {

    public enum Stage: Sendable, Equatable {
        case notStarted
        /// Collecting samples for this phase.
        case measuring(CalibrationPhase)
        /// The near phase is done; the user is being asked to walk to where they usually leave.
        case readyForFar
        case succeeded(CalibrationProfile)
        case failed(CalibrationFlowError)
    }

    public let device: DeviceID
    public let policy: CalibrationPolicy

    public private(set) var stage: Stage = .notStarted
    /// Samples counted per phase, for the live "n readings" label.
    public private(set) var session: CalibrationSession

    public init(device: DeviceID, policy: CalibrationPolicy = CalibrationPolicy()) {
        self.device = device
        self.policy = policy
        self.session = CalibrationSession(policy: policy)
    }

    // MARK: - Progress

    public func sampleCount(for phase: CalibrationPhase) -> Int {
        session.progress(for: phase).samples
    }

    public func elapsed(for phase: CalibrationPhase) -> Duration {
        session.progress(for: phase).elapsed
    }

    /// 0…1, for a determinate progress bar.
    ///
    /// The minimum of the two ratios, because §7.2 requires *both* the sample count and the
    /// covered span to clear their thresholds. Showing the larger of the two would let the bar
    /// fill while the phase was still short, and the user would press Continue into an
    /// `insufficientSamples` failure.
    public func progress(for phase: CalibrationPhase) -> Double {
        let (samples, elapsed) = session.progress(for: phase)
        let bySamples = policy.minSamples > 0 ? Double(samples) / Double(policy.minSamples) : 1
        let requiredNanoseconds = policy.minDuration.wholeNanoseconds
        let byDuration = requiredNanoseconds > 0
            ? Double(elapsed.wholeNanoseconds) / Double(requiredNanoseconds)
            : 1
        return min(1, max(0, min(bySamples, byDuration)))
    }

    /// Whether this phase has met the §7.2 minimums and the user may move on.
    public func isComplete(_ phase: CalibrationPhase) -> Bool {
        let (samples, elapsed) = session.progress(for: phase)
        return samples >= policy.minSamples && elapsed >= policy.minDuration
    }

    public var currentPhase: CalibrationPhase? {
        if case .measuring(let phase) = stage { return phase }
        return nil
    }

    public var isMeasuring: Bool { currentPhase != nil }

    // MARK: - Transitions

    /// Starts (or restarts) the run at the near phase, discarding any samples already taken.
    public func beginNear() {
        session = CalibrationSession(policy: policy)
        stage = .measuring(.near)
    }

    /// Files one observation under the phase currently being measured.
    ///
    /// Observations for other devices are ignored rather than merged: a profile is per device
    /// and mixing two devices' baselines would produce a plausible-looking, meaningless one.
    /// Observations arriving outside a measuring stage are ignored too, so the seconds a user
    /// spends reading the "now walk away" screen do not silently land in the far phase.
    public func ingest(_ observation: BLEObservation) {
        guard observation.device == device, case .measuring(let phase) = stage else { return }
        session.add(observation.rssi, at: observation.at, phase: phase)
    }

    /// Near → the walk-away instruction screen.
    public func completeNear() {
        guard case .measuring(.near) = stage else { return }
        stage = .readyForFar
    }

    /// The instruction screen → measuring the far phase.
    public func beginFar() {
        guard stage == .readyForFar else { return }
        stage = .measuring(.far)
    }

    /// Evaluates the session and, on success, builds the record to persist.
    ///
    /// Callable at any time, including early: an under-length run comes back as
    /// `insufficientSamples`, which is exactly what the user should be told. Persisting is the
    /// caller's job — the flow has no store, so what it returns is a record, not a promise
    /// that one was written.
    @discardableResult
    public func finish(environment: CalibrationEnvironment) -> Result<CalibrationRecord, CalibrationFlowError> {
        switch session.finish() {
        case .failure(let failure):
            stage = .failed(.measurement(failure))
            return .failure(.measurement(failure))
        case .success(let profile):
            guard let macIdentity = environment.macIdentity else {
                stage = .failed(.machineIdentityUnavailable)
                return .failure(.machineIdentityUnavailable)
            }
            let record = CalibrationRecord(
                device: device,
                macIdentity: macIdentity,
                profile: profile,
                osMajorVersion: environment.osMajorVersion,
                appVersion: environment.appVersion,
                createdAtUnixSeconds: environment.nowUnixSeconds
            )
            stage = .succeeded(profile)
            return .success(record)
        }
    }

    /// Records a persistence failure after `finish()` succeeded, so the UI stops showing success.
    public func saveFailed(_ message: String) {
        stage = .failed(.saveFailed(message))
    }

    /// The message under the failure, or `nil` when nothing has failed.
    public var failureMessage: String? {
        guard case .failed(let error) = stage else { return nil }
        return PlainLanguage.calibrationError(error)
    }
}
