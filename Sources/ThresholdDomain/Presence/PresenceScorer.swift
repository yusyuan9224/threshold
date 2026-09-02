/// Turns one device's `SignalEstimate` into the three explainable factors of a `PresenceScore`
/// (docs/specs/proximity-domain.md §3.1). Pure: `now` arrives as an argument, never from a clock.
public struct PresenceScorer: Sendable, Equatable {
    public let configuration: EngineConfiguration

    public init(configuration: EngineConfiguration = EngineConfiguration()) {
        self.configuration = configuration
    }

    public func score(for estimate: SignalEstimate, now: MonotonicInstant, profile: CalibrationProfile) -> PresenceScore {
        PresenceScore(
            distance: distance(smoothedRSSI: estimate.smoothedRSSI, profile: profile),
            recency: recency(lastSeen: estimate.lastSeen, now: now),
            sufficiency: sufficiency(sampleCount: estimate.sampleCount)
        )
    }

    /// How "near" the signal is relative to the calibrated baselines. A logistic rather than a
    /// hard dBm threshold: the answer degrades smoothly through the uncertain band instead of
    /// flipping on one dB of noise.
    func distance(smoothedRSSI: Double, profile: CalibrationProfile) -> Double {
        // A non-positive slope would make the logistic a step function; fall back to the
        // display default rather than dividing by zero.
        let slope = profile.slope > 0 ? profile.slope : CalibrationProfile.default.slope
        return Math.logistic((smoothedRSSI - profile.midpoint) / slope)
    }

    /// Full while the sample is fresh, then linear to zero at `silentThreshold` — the instant the
    /// device is declared silent and drops out of fusion entirely. It only smooths the last seconds
    /// before silence; it must never be the thing that produces a false `away` (§3.1).
    func recency(lastSeen: MonotonicInstant, now: MonotonicInstant) -> Double {
        let age = Double((now - lastSeen).wholeNanoseconds)
        let full = Double(configuration.recencyFullUntil.wholeNanoseconds)
        let silent = Double(configuration.silentThreshold.wholeNanoseconds)
        if age <= full { return 1 }
        guard silent > full else { return 0 }
        if age >= silent { return 0 }
        return 1 - (age - full) / (silent - full)
    }

    /// Too few samples are not trustworthy. This factor is what makes "lock or wake within
    /// 3 s of a reset" impossible however strong the signal is.
    func sufficiency(sampleCount: Int) -> Double {
        guard configuration.minSamples > 0 else { return 1 }
        let ratio = Double(sampleCount) / Double(configuration.minSamples)
        return ratio < 1 ? ratio : 1
    }
}
