import ThresholdDomain

/// Time source for every system boundary.
///
/// Time is produced **only** at boundaries: the scanner and the providers stamp values with
/// `clock.now()` as they yield. The Domain never reads a clock — it consumes the
/// `MonotonicInstant` carried inside its inputs (docs/specs/architecture.md §4.2).
///
/// Production uses `ContinuousMonotonicClock`; tests use `FakeClock`.
public protocol MonotonicClock: Sendable {
    /// The current monotonic instant. Never runs backwards and keeps advancing across system sleep.
    func now() -> MonotonicInstant

    /// Suspends until `deadline`. Returns immediately when `deadline` is already in the past.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled while suspended.
    func sleep(until deadline: MonotonicInstant) async throws
}

extension MonotonicClock {
    /// Convenience: suspend for `duration`, measured from the current instant.
    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now() + duration)
    }
}
