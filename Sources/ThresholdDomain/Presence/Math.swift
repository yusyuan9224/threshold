/// Transcendental functions the Domain needs but the Swift standard library does not provide.
///
/// `ThresholdDomain` imports nothing — not Foundation, not Darwin — so `exp` is implemented here
/// by range reduction plus a Taylor series. Accuracy is better than 1e-15 relative, which is far
/// beyond what a logistic over dBm values needs, and the result is deterministic on every host.
enum Math {
    // ln 2 split into two doubles so `x − k·ln2` keeps its low-order bits.
    private static let ln2Hi = 0.693147180369123816490
    private static let ln2Lo = 1.90821492927058770002e-10
    private static let log2e = 1.442695040888963407360
    /// exp overflows a Double above this; exp underflows to zero below the negative bound.
    private static let overflowThreshold = 709.782712893384
    private static let underflowThreshold = -745.133219101941

    /// e^x. Saturates to `greatestFiniteMagnitude` / `0` instead of producing an infinity,
    /// so no NaN can ever leak out of a downstream division.
    static func exp(_ x: Double) -> Double {
        if x.isNaN { return x }
        if x > overflowThreshold { return .greatestFiniteMagnitude }
        if x < underflowThreshold { return 0 }

        let k = (x * log2e).rounded(.toNearestOrEven)
        // |r| ≤ ln2/2 ≈ 0.347, where 13 series terms are exact to the last bit.
        let r = (x - k * ln2Hi) - k * ln2Lo

        var term = 1.0
        var sum = 1.0
        for n in 1...13 {
            term *= r / Double(n)
            sum += term
        }
        return sum * Double(sign: .plus, exponent: Int(k), significand: 1)
    }

    /// 1 / (1 + e^(−x)), evaluated in whichever of its two algebraically equal forms
    /// avoids cancellation, so the result stays inside [0, 1] for every input.
    static func logistic(_ x: Double) -> Double {
        if x >= 0 {
            return 1 / (1 + exp(-x))
        }
        let e = exp(x)
        return e / (1 + e)
    }
}
