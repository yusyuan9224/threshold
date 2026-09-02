/// Additive: `finish()` reports failure as `Result`, which requires the failure type to be
/// an `Error`. Declared here rather than edited into the type so the §7.1 skeleton stays as
/// written. No case, payload or spelling changes.
extension CalibrationFailure: Error {}

/// Collects the two calibration phases and turns them into a profile — or an honest failure
/// (docs/specs/proximity-domain.md §7.2).
///
/// Pure and input-driven: the UI feeds samples with the `MonotonicInstant` they arrived at,
/// and the session never reads a clock (ADR-003 §1). Nothing is decided until `finish()`,
/// so `progress(for:)` can drive a UI without committing to an outcome.
public struct CalibrationSession: Sendable, Equatable {

    struct Sample: Sendable, Equatable {
        let rssi: Int
        let at: MonotonicInstant
    }

    public let policy: CalibrationPolicy
    private var near: [Sample] = []
    private var far: [Sample] = []

    public init(policy: CalibrationPolicy = CalibrationPolicy()) {
        self.policy = policy
    }

    /// Records one sample against a phase. Out-of-order instants are accepted: `progress`
    /// spans earliest to latest rather than assuming arrival order.
    public mutating func add(_ rssi: Int, at: MonotonicInstant, phase: CalibrationPhase) {
        let sample = Sample(rssi: rssi, at: at)
        switch phase {
        case .near: near.append(sample)
        case .far: far.append(sample)
        }
    }

    /// Sample count and covered span for one phase, for progress UI. Zero-length when the
    /// phase holds fewer than two samples.
    public func progress(for phase: CalibrationPhase) -> (samples: Int, elapsed: Duration) {
        let samples = self[phase]
        let instants = samples.map { $0.at }
        guard let first = instants.min(), let last = instants.max() else { return (0, .zero) }
        return (samples.count, last - first)
    }

    /// Applies §7.2 in order: insufficient samples → too noisy → overlap → profile.
    ///
    /// The order matters. A short run is reported as short even if it also looks noisy,
    /// because "keep going" is more useful to the user than "your room is bad"; and an
    /// overlap verdict is only meaningful once both phases are long enough and quiet enough
    /// for their medians to mean something.
    public func finish() -> Result<CalibrationProfile, CalibrationFailure> {
        for phase in [CalibrationPhase.near, .far] {
            let (samples, elapsed) = progress(for: phase)
            if samples < policy.minSamples || elapsed < policy.minDuration {
                return .failure(.insufficientSamples(phase: phase))
            }
        }

        let nearValues = near.map { Double($0.rssi) }
        let farValues = far.map { Double($0.rssi) }
        guard
            let nearBaseline = CalibrationStats.median(nearValues),
            let farBaseline = CalibrationStats.median(farValues),
            let nearNoise = CalibrationStats.medianAbsoluteDeviation(nearValues),
            let farNoise = CalibrationStats.medianAbsoluteDeviation(farValues)
        else {
            // Unreachable: the sample-count gate above guarantees both phases are non-empty.
            return .failure(.insufficientSamples(phase: .near))
        }

        if nearNoise > policy.maxNoiseDB { return .failure(.tooNoisy(phase: .near)) }
        if farNoise > policy.maxNoiseDB { return .failure(.tooNoisy(phase: .far)) }

        // Separation must beat both a fixed floor and the noise actually measured: a 10 dB gap
        // between two phases that each wobble by 4 dB is not a gap. Reporting `.overlap` is
        // more honest than silently handing Policy a threshold that cannot separate anything.
        let separation = nearBaseline - farBaseline
        let requiredSeparation = max(policy.minSeparationDB, 3 * max(nearNoise, farNoise))
        if separation < requiredSeparation { return .failure(.overlap) }

        return .success(
            CalibrationProfile(
                nearBaseline: nearBaseline,
                farBaseline: farBaseline,
                noise: max(nearNoise, farNoise),
                midpoint: (nearBaseline + farBaseline) / 2,
                slope: (nearBaseline - farBaseline) / 4
            )
        )
    }

    private subscript(phase: CalibrationPhase) -> [Sample] {
        switch phase {
        case .near: return near
        case .far: return far
        }
    }
}
