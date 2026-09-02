import ThresholdDomain

/// Test double for `ScreenStateProviding`. Starts `.unknown` so a test has to state what the system
/// knows (docs/specs/system-integration.md: every Fake must be able to report `.unknown`).
public final class FakeScreenStateProvider: ScreenStateProviding, Sendable {
    private let base: ObservableValue<ScreenState>

    public init(initial: ScreenState = .unknown) { base = ObservableValue(initial) }

    public var current: ScreenState { base.value }
    public var changes: AsyncStream<Timestamped<ScreenState>> { base.changes }

    /// Changes what `current` reports without emitting on `changes`.
    public func set(_ state: ScreenState) { base.set(state) }
    /// Changes `current` and emits the new value.
    public func push(_ state: ScreenState, at instant: MonotonicInstant = .zero) { base.push(state, at: instant) }
    public func finish() { base.finish() }
}

/// Test double for `SessionStateProviding`.
public final class FakeSessionStateProvider: SessionStateProviding, Sendable {
    private let base: ObservableValue<SessionState>

    public init(initial: SessionState = .unknown) { base = ObservableValue(initial) }

    public var current: SessionState { base.value }
    public var changes: AsyncStream<Timestamped<SessionState>> { base.changes }

    public func set(_ state: SessionState) { base.set(state) }
    public func push(_ state: SessionState, at instant: MonotonicInstant = .zero) { base.push(state, at: instant) }
    public func finish() { base.finish() }
}

/// Test double for `PowerStateProviding`.
public final class FakePowerStateProvider: PowerStateProviding, Sendable {
    private let base: ObservableValue<PowerState>

    public init(initial: PowerState = .unknown) { base = ObservableValue(initial) }

    public var current: PowerState { base.value }
    public var changes: AsyncStream<Timestamped<PowerState>> { base.changes }

    public func set(_ state: PowerState) { base.set(state) }
    public func push(_ state: PowerState, at instant: MonotonicInstant = .zero) { base.push(state, at: instant) }
    public func finish() { base.finish() }
}

/// Test double for `InputActivityProviding`. Defaults to `nil`, which is the production contract
/// until SPIKE-008 has run.
public final class FakeInputActivityProvider: InputActivityProviding, Sendable {
    private let base: ObservableValue<Duration?>

    public init(idle: Duration? = nil) { base = ObservableValue(idle) }

    public var current: Duration? { base.value }

    public func set(_ idle: Duration?) { base.set(idle) }
}
