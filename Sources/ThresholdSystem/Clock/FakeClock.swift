import os
import ThresholdDomain

/// Test `MonotonicClock` whose time only moves when a test moves it.
///
/// Every timing-sensitive rule in the engine (hold windows, grace periods, wake blackout, lock
/// deadlines) is expressed against a `MonotonicInstant`. Driving those rules from a real clock would
/// make L3 tests slow and flaky, so the integration layer injects this clock instead and steps time
/// explicitly with `advance(by:)` / `advance(to:)` (docs/specs/testing.md §2, L3).
///
/// `sleep(until:)` suspends until an `advance` carries the clock to or past the deadline. When one
/// step crosses several deadlines, the reached sleepers are resumed in deadline order (ties broken
/// by registration order), matching the order a real clock would have released them. Resuming only
/// makes a task runnable: when each one is actually scheduled afterwards is the concurrency
/// runtime's choice, so a test that needs a strict order should step the clock one deadline at a
/// time.
///
/// Safe to use from several tasks at once: all mutable state lives behind a single lock, and
/// continuations are always resumed *outside* that lock.
public final class FakeClock: MonotonicClock, Sendable {
    private struct Sleeper: Sendable {
        let id: UInt64
        let deadline: MonotonicInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var now: MonotonicInstant
        var nextSleeperID: UInt64 = 0
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled in the window between claiming an id and registering the continuation.
        var cancelledBeforeRegistration: Set<UInt64> = []
    }

    /// What `sleep(until:)` must do with a freshly created continuation.
    private enum Registration: Sendable {
        case suspended
        case deadlinePassed
        case cancelled
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(start: MonotonicInstant = MonotonicInstant(nanoseconds: 0)) {
        state = OSAllocatedUnfairLock(initialState: State(now: start))
    }

    // MARK: - MonotonicClock

    public func now() -> MonotonicInstant {
        state.withLock { $0.now }
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        // Claim an id only when the sleep will actually suspend; a past deadline returns at once.
        let claimed: UInt64? = state.withLock { s in
            guard deadline > s.now else { return nil }
            let id = s.nextSleeperID
            s.nextSleeperID &+= 1
            return id
        }
        guard let id = claimed else { return }

        // Runs once `withTaskCancellationHandler` has unregistered `onCancel`, so a late
        // cancellation can no longer leave an entry behind.
        defer { state.withLock { _ = $0.cancelledBeforeRegistration.remove(id) } }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration: Registration = state.withLock { s in
                    if s.cancelledBeforeRegistration.contains(id) { return .cancelled }
                    guard deadline > s.now else { return .deadlinePassed }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .suspended
                }
                switch registration {
                case .suspended: break
                case .deadlinePassed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { s in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else {
                    // Cancelled before the continuation was registered; the body will see this.
                    s.cancelledBeforeRegistration.insert(id)
                    return nil
                }
                return s.sleepers.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    // MARK: - Test control

    /// Sleepers currently suspended on this clock. Lets a test wait for a suspension instead of
    /// guessing at it with a real delay.
    public var pendingSleepers: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves time forward by `duration` and wakes every sleeper it reaches.
    public func advance(by duration: Duration) {
        wake { $0 + duration }
    }

    /// Moves time to `instant` and wakes every sleeper it reaches.
    ///
    /// An instant in the past is ignored: a monotonic clock never runs backwards.
    public func advance(to instant: MonotonicInstant) {
        wake { max($0, instant) }
    }

    private func wake(_ transform: @Sendable (MonotonicInstant) -> MonotonicInstant) {
        let due: [Sleeper] = state.withLock { s in
            s.now = transform(s.now)
            let now = s.now
            let reached = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            // Deadline order, with registration order breaking ties.
            return reached.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}
