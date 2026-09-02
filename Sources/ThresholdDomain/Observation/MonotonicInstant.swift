/// Monotonic time carried by every engine input. Produced only at system boundaries
/// (see `MonotonicClock` in ThresholdSystem); the Domain never reads a clock.
///
/// Must never be persisted: it is not meaningful across process or reboot boundaries.
public struct MonotonicInstant: Comparable, Hashable, Codable, Sendable {
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    /// Origin used by fixtures (`t0 = 0`).
    public static let zero = MonotonicInstant(nanoseconds: 0)

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    public static func + (lhs: Self, rhs: Duration) -> Self {
        MonotonicInstant(nanoseconds: lhs.nanoseconds + rhs.wholeNanoseconds)
    }

    public static func - (lhs: Self, rhs: Duration) -> Self {
        MonotonicInstant(nanoseconds: lhs.nanoseconds - rhs.wholeNanoseconds)
    }

    /// Elapsed duration from `rhs` to `lhs`. Negative if `lhs` precedes `rhs`.
    public static func - (lhs: Self, rhs: Self) -> Duration {
        .nanoseconds(lhs.nanoseconds - rhs.nanoseconds)
    }
}

extension Duration {
    /// Whole nanoseconds, truncating attoseconds. Sufficient for all Domain timing.
    public var wholeNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
