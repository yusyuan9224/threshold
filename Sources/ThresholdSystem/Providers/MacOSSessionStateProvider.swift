import Foundation
import os
import ThresholdDomain

/// Production `SessionStateProviding`.
///
/// The `NSWorkspace` session notifications are only a cue: the answer always comes from
/// `kCGSessionOnConsoleKey`, so a missing or unrecognised key reports `.unknown` rather than
/// letting a notification assert a state the window server will not confirm (security.md §2 rule 1).
public final class MacOSSessionStateProvider: SessionStateProviding, Sendable {
    private let clock: any MonotonicClock
    private let reported: OSAllocatedUnfairLock<SessionState>
    private let stream: AsyncStream<Timestamped<SessionState>>
    private let continuation: AsyncStream<Timestamped<SessionState>>.Continuation
    private let observers = NotificationObservers()

    public init(clock: any MonotonicClock) {
        self.clock = clock
        reported = OSAllocatedUnfairLock(initialState: SessionStateMapping.current())
        let (stream, continuation) = AsyncStream<Timestamped<SessionState>>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation

        let workspace = NSWorkspaceNotifications.center
        observers.add(workspace, name: NSWorkspaceNotifications.sessionDidBecomeActive) { [weak self] in self?.refresh() }
        observers.add(workspace, name: NSWorkspaceNotifications.sessionDidResignActive) { [weak self] in self?.refresh() }
    }

    deinit {
        observers.removeAll()
        continuation.finish()
    }

    public var current: SessionState { SessionStateMapping.current() }

    public var changes: AsyncStream<Timestamped<SessionState>> { stream }

    private func refresh() {
        let query = SessionStateMapping.current()
        let changed = reported.withLock { reported -> Bool in
            guard reported != query else { return false }
            reported = query
            return true
        }
        guard changed else { return }
        continuation.yield(Timestamped(query, at: clock.now()))
    }
}
