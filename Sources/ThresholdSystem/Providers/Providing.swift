import ThresholdDomain

/// Lock state of the screen. `current` is a synchronous window-server query; `changes` is driven by
/// the lock/unlock notifications, reconciled with the query by `ScreenStateSynthesizer`.
public protocol ScreenStateProviding: Sendable {
    var current: ScreenState { get }
    var changes: AsyncStream<Timestamped<ScreenState>> { get }
}

/// Whether this login session owns the console. Fast user switching and remote sessions move it.
public protocol SessionStateProviding: Sendable {
    var current: SessionState { get }
    var changes: AsyncStream<Timestamped<SessionState>> { get }
}

/// System and display sleep state.
public protocol PowerStateProviding: Sendable {
    var current: PowerState { get }
    var changes: AsyncStream<Timestamped<PowerState>> { get }
}

/// How long the user has been idle at the keyboard, mouse and trackpad, or `nil` when that cannot be
/// established.
///
/// There is no `changes` stream: no system signal announces the *start* of idleness, and the
/// Coordinator samples this value when it builds a `PolicySnapshot` (architecture.md §5.1).
///
/// `nil` is a first-class answer, not a failure. Policy must treat it as "unknown" and apply
/// security.md §2 rules 3 and 7: missing supporting evidence blocks a silence-based lock but does
/// not block a `measuredFar` lock.
public protocol InputActivityProviding: Sendable {
    var current: Duration? { get }
}
