/// One pipeline per device: window → median → EMA → `SignalEstimate`
/// (docs/specs/proximity-domain.md §2). Pure and input-driven; it never reads a clock.
public struct SignalPipeline: Sendable, Equatable {
    private var window: SignalWindow
    private var median: MedianFilter
    private var ema: EMAFilter

    /// Latest estimate, or `nil` before the first accepted sample and after `reset()`.
    public private(set) var estimate: SignalEstimate?

    public init(configuration: EngineConfiguration) {
        self.window = SignalWindow(size: configuration.windowSize, horizon: configuration.windowHorizon)
        self.median = MedianFilter(span: configuration.medianSpan)
        self.ema = EMAFilter(alpha: configuration.emaAlpha)
    }

    /// Feeds one *already validated* sample through the pipeline.
    @discardableResult
    public mutating func ingest(rssi: Int, at instant: MonotonicInstant) -> SignalEstimate {
        window.append(rssi: rssi, at: instant)
        // The window is non-empty here, so the median is defined.
        let filtered = median.filter(window) ?? Double(rssi)
        let smoothed = ema.update(filtered)
        let produced = SignalEstimate(
            smoothedRSSI: smoothed,
            sampleCount: window.count,
            lastSeen: instant,
            spread: window.medianAbsoluteDeviation
        )
        estimate = produced
        return produced
    }

    /// Drops all history. Used by `reset(_:)`, where evidence gathered before the reset
    /// must not influence the new episode.
    public mutating func reset() {
        window.removeAll()
        ema.reset()
        estimate = nil
    }
}
