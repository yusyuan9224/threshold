/// Tunable inputs to every Calibration rule (docs/specs/proximity-domain.md §7.4).
///
/// **These numbers have no measured basis.** They are engineering starting values to be
/// revisited with MVP 1B recordings and alpha issues; they are not product requirements.
public struct CalibrationPolicy: Codable, Sendable, Equatable {

    // MARK: Profile lifetime and drift (§7.4)

    /// Age-based revalidation. The architecture supports it; MVP leaves it disabled (`nil`),
    /// so an old profile still arms. See §7.3.
    public var maxProfileAge: Duration?

    /// Deviation from `nearBaseline` that makes drift *suspected* and worth reporting.
    public var driftSuspectThresholdDB: Double

    /// The rolling window drift is measured over.
    public var driftWindow: Duration

    /// Post-MVP decision; off by default. MVP only detects drift and recommends recalibration.
    public var autoDisarmOnDrift: Bool

    /// Deviation at which drift would disarm the gate — but only when `autoDisarmOnDrift`.
    public var driftDisarmThresholdDB: Double

    // MARK: Session parameters (§7.2)

    /// Minimum wall span each phase must cover before it can be trusted.
    public var minDuration: Duration

    /// Minimum sample count per phase, and the minimum for a revalidation near-run.
    public var minSamples: Int

    /// A phase whose MAD exceeds this is too noisy to calibrate from.
    public var maxNoiseDB: Double

    /// Floor on the near/far separation, before the noise-scaled term is considered.
    public var minSeparationDB: Double

    /// Floor on the revalidation tolerance band around `nearBaseline` (§7.3).
    public var revalidationToleranceDB: Double

    public init(
        maxProfileAge: Duration? = nil,
        driftSuspectThresholdDB: Double = 8,
        driftWindow: Duration = .seconds(1800),
        autoDisarmOnDrift: Bool = false,
        driftDisarmThresholdDB: Double = 15,
        minDuration: Duration = .seconds(20),
        minSamples: Int = 15,
        maxNoiseDB: Double = 6,
        minSeparationDB: Double = 8,
        revalidationToleranceDB: Double = 6
    ) {
        self.maxProfileAge = maxProfileAge
        self.driftSuspectThresholdDB = driftSuspectThresholdDB
        self.driftWindow = driftWindow
        self.autoDisarmOnDrift = autoDisarmOnDrift
        self.driftDisarmThresholdDB = driftDisarmThresholdDB
        self.minDuration = minDuration
        self.minSamples = minSamples
        self.maxNoiseDB = maxNoiseDB
        self.minSeparationDB = minSeparationDB
        self.revalidationToleranceDB = revalidationToleranceDB
    }
}
