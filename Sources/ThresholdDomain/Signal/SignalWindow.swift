/// Bounded, time-limited history of raw samples for one device (docs/specs/proximity-domain.md §2).
///
/// Two independent bounds: at most `size` samples, and nothing older than `horizon` behind the
/// newest sample. The horizon matters because a device that goes quiet for a minute and comes
/// back must not be smoothed against pre-silence history.
public struct SignalWindow: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let rssi: Int
        public let at: MonotonicInstant
        public init(rssi: Int, at: MonotonicInstant) { self.rssi = rssi; self.at = at }
    }

    public let size: Int
    public let horizon: Duration
    /// Oldest first, newest last.
    public private(set) var samples: [Sample] = []

    public init(size: Int, horizon: Duration) {
        self.size = size
        self.horizon = horizon
    }

    public var count: Int { samples.count }
    public var isEmpty: Bool { samples.isEmpty }
    public var newest: Sample? { samples.last }
    public var values: [Double] { samples.map { Double($0.rssi) } }

    /// Appends and re-applies both bounds. Samples older than the new sample by more than
    /// `horizon` are dropped, then the window is trimmed to `size`.
    public mutating func append(rssi: Int, at instant: MonotonicInstant) {
        samples.append(Sample(rssi: rssi, at: instant))
        let cutoff = instant - horizon
        samples.removeAll { $0.at < cutoff }
        if samples.count > size {
            samples.removeFirst(samples.count - size)
        }
    }

    public mutating func removeAll() { samples.removeAll() }

    /// The newest `span` values, oldest first. Fewer if the window holds fewer.
    public func newestValues(_ span: Int) -> [Double] {
        let take = span < count ? span : count
        return samples.suffix(take).map { Double($0.rssi) }
    }

    /// Median absolute deviation of the whole window, in dB. Zero for an empty window.
    /// Chosen over standard deviation because one `-20` spike must not inflate the reported spread.
    public var medianAbsoluteDeviation: Double {
        guard let centre = MedianFilter.median(of: values) else { return 0 }
        let deviations = values.map { $0 < centre ? centre - $0 : $0 - centre }
        return MedianFilter.median(of: deviations) ?? 0
    }
}
