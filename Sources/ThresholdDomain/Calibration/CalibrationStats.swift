/// Robust statistics used by the Calibration rules (docs/specs/proximity-domain.md §7.2).
///
/// Median and MAD rather than mean and standard deviation: a single RSSI spike must not
/// move a baseline or inflate a noise estimate.
///
/// Deliberately `internal` and scoped to `Calibration/` — other engine areas keep their own
/// helpers so the two never have to agree on a shared numeric contract.
enum CalibrationStats {
    /// Median of `values`; `nil` when empty. Even counts average the two middle elements.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Median absolute deviation: `median(|x − median(x)|)`. `nil` when empty.
    static func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard let centre = median(values) else { return nil }
        return median(values.map { abs($0 - centre) })
    }
}
