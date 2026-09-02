/// Rejects single-sample spikes before they can reach the exponential average
/// (docs/specs/proximity-domain.md §2). A reflected or momentarily boosted advertisement
/// shows up as one extreme sample; the median of the span ignores it entirely.
public struct MedianFilter: Sendable, Equatable {
    public let span: Int

    public init(span: Int) { self.span = span }

    /// Median of the newest `span` samples, or of everything available when the window holds fewer.
    /// `nil` for an empty window.
    public func filter(_ window: SignalWindow) -> Double? {
        MedianFilter.median(of: window.newestValues(span))
    }

    /// Median of an unsorted collection. Even counts average the two middle values.
    public static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// Exponential moving average over the median-filtered stream.
/// Seeds on the first value rather than starting from zero, so the first estimate is
/// the first measurement instead of a 60 dB transient.
public struct EMAFilter: Sendable, Equatable {
    public let alpha: Double
    public private(set) var value: Double?

    public init(alpha: Double) { self.alpha = alpha }

    @discardableResult
    public mutating func update(_ input: Double) -> Double {
        let updated = value.map { alpha * input + (1 - alpha) * $0 } ?? input
        value = updated
        return updated
    }

    public mutating func reset() { value = nil }
}
