/// Output of the per-device signal pipeline (docs/specs/proximity-domain.md §2).
public struct SignalEstimate: Sendable, Equatable {
    public let smoothedRSSI: Double
    public let sampleCount: Int
    public let lastSeen: MonotonicInstant
    /// Median absolute deviation of the current window, in dB.
    public let spread: Double

    public init(smoothedRSSI: Double, sampleCount: Int, lastSeen: MonotonicInstant, spread: Double) {
        self.smoothedRSSI = smoothedRSSI
        self.sampleCount = sampleCount
        self.lastSeen = lastSeen
        self.spread = spread
    }
}
