/// How far the at-desk signal has moved from the calibrated near baseline
/// (docs/specs/proximity-domain.md §7.5). The deviation travels with the verdict so
/// diagnostics can show the number, not just the label.
public enum DriftAssessment: Sendable, Equatable {
    case none
    case suspected(deviationDB: Double)
    case exceeded(deviationDB: Double)
}

/// Detects a calibration that no longer matches the room (§7.5).
///
/// A desk moves, a laptop lid angle changes, a new monitor lands between the Mac and the phone —
/// the profile is still valid arithmetic, but it now describes somewhere else. MVP only detects:
/// it reports to diagnostics and recommends recalibration, and disarms only if the operator
/// explicitly opted in via `autoDisarmOnDrift`.
///
/// Pure. The caller is responsible for supplying samples gathered **only** under strong at-desk
/// evidence (`presence == present ∧ screen == unlocked ∧ inputIdle < 30 s`); the detector cannot
/// verify that and does not try.
public struct DriftDetector: Sendable, Equatable {

    public init() {}

    /// Deviation of the rolling median over the last `driftWindow` from `nearBaseline`.
    ///
    /// Returns `.none` unless the series actually spans the whole window: a large deviation
    /// measured over five minutes is a bad afternoon, not drift. That is the "sustained"
    /// requirement — and the median inside the window absorbs brief excursions, so a couple of
    /// bad minutes cannot trip it either.
    public func assess(
        record: CalibrationRecord,
        samples: [(smoothedRSSI: Double, at: MonotonicInstant)],
        policy: CalibrationPolicy
    ) -> DriftAssessment {
        let instants = samples.map { $0.at }
        guard let earliest = instants.min(), let latest = instants.max() else { return .none }
        guard latest - earliest >= policy.driftWindow else { return .none }

        let windowStart = latest - policy.driftWindow
        let window = samples.filter { $0.at >= windowStart }.map { $0.smoothedRSSI }
        guard let median = CalibrationStats.median(window) else { return .none }

        // Absolute: a baseline that drifted *stronger* is as wrong as one that drifted weaker.
        let deviation = abs(median - record.profile.nearBaseline)
        if deviation > policy.driftDisarmThresholdDB { return .exceeded(deviationDB: deviation) }
        if deviation > policy.driftSuspectThresholdDB { return .suspected(deviationDB: deviation) }
        return .none
    }

    /// Applies an assessment to a gate. Drift can only ever *remove* trust:
    /// it never arms, and it never overwrites a reason the operator still needs to see.
    public func gateAfterDrift(
        _ current: CalibrationGate,
        assessment: DriftAssessment,
        policy: CalibrationPolicy
    ) -> CalibrationGate {
        guard policy.autoDisarmOnDrift, case .exceeded = assessment, current.isArmed else {
            return current
        }
        return .notArmed(.driftExceeded)
    }
}
