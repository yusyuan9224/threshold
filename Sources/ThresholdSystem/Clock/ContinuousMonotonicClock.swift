import ThresholdDomain

/// Production `MonotonicClock`, backed by `ContinuousClock`.
///
/// `ContinuousClock` keeps counting while the machine is asleep, which is exactly the semantics
/// the proximity engine needs: a gap in observations across a sleep/wake cycle must read as a real
/// elapsed gap, not as a frozen clock (docs/specs/system-integration.md §4).
///
/// Instants are reported as nanoseconds since a process-local origin. The origin is captured lazily
/// on first use rather than literally at `main()`, which is immaterial: `MonotonicInstant` is only
/// ever compared and subtracted within one process, and is explicitly not persistable.
public struct ContinuousMonotonicClock: MonotonicClock {
    /// Process-local zero point. Lazily initialised on first access, then fixed for the process.
    private static let origin = ContinuousClock.now

    private let clock = ContinuousClock()

    public init() {}

    public func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: (clock.now - Self.origin).wholeNanoseconds)
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        let remaining = deadline.nanoseconds - now().nanoseconds
        guard remaining > 0 else { return }
        try await clock.sleep(until: clock.now + .nanoseconds(remaining))
    }
}
