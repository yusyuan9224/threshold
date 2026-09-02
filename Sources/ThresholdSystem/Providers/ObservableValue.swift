import os
import ThresholdDomain

/// A lock-protected value plus a change stream: the shared machinery behind the Fake providers.
///
/// All mutable state lives inside a single `OSAllocatedUnfairLock`, and the continuation is a `let`,
/// so the enclosing provider is `Sendable` without `@unchecked` (architecture.md §4.1).
final class ObservableValue<Value: Sendable & Equatable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>
    private let stream: AsyncStream<Timestamped<Value>>
    private let continuation: AsyncStream<Timestamped<Value>>.Continuation

    init(_ initial: Value, bufferingPolicy: AsyncStream<Timestamped<Value>>.Continuation.BufferingPolicy = .unbounded) {
        state = OSAllocatedUnfairLock(initialState: initial)
        let (stream, continuation) = AsyncStream<Timestamped<Value>>.makeStream(bufferingPolicy: bufferingPolicy)
        self.stream = stream
        self.continuation = continuation
    }

    var value: Value { state.withLock { $0 } }

    var changes: AsyncStream<Timestamped<Value>> { stream }

    /// Updates the value without emitting: models a system state a test wants readable through
    /// `current` but not announced on the stream.
    func set(_ newValue: Value) {
        state.withLock { $0 = newValue }
    }

    /// Updates the value and emits it.
    func push(_ newValue: Value, at instant: MonotonicInstant) {
        state.withLock { $0 = newValue }
        continuation.yield(Timestamped(newValue, at: instant))
    }

    /// Emits without changing the stored value.
    func emit(_ newValue: Value, at instant: MonotonicInstant) {
        continuation.yield(Timestamped(newValue, at: instant))
    }

    func finish() {
        continuation.finish()
    }
}
