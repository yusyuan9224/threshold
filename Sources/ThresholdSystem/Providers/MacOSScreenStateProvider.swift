import Foundation
import os
import ThresholdDomain

/// Production `ScreenStateProviding`.
///
/// `current` is the window-server query alone: it is synchronous, cheap, and SPIKE-001 showed it is
/// the source that flips first. `changes` is notification-driven, with `ScreenStateSynthesizer`
/// deciding whether a signal can be reported straight away or needs a settling window first.
///
/// ADR-004: the undocumented notification names live here and nowhere else. If Apple retires them,
/// only this file changes; Domain and Coordinator do not.
public final class MacOSScreenStateProvider: ScreenStateProviding, Sendable {
    private struct State: Sendable {
        var synthesizer: ScreenStateSynthesizer
        /// Bumped by every signal. A settling task whose generation is stale has been overtaken by
        /// a newer signal and must not report anything.
        var generation: UInt64 = 0
    }

    private let clock: any MonotonicClock
    private let settlingWindow: Duration
    private let state: OSAllocatedUnfairLock<State>
    private let stream: AsyncStream<Timestamped<ScreenState>>
    private let continuation: AsyncStream<Timestamped<ScreenState>>.Continuation
    private let observers = NotificationObservers()

    /// - Parameter settlingWindow: how long to wait before re-reading the query when a notification
    ///   and the query disagree. SPIKE-001 never observed a disagreement, so this is a safety net
    ///   rather than a measured value; 500 ms is well past the 10-110 ms notification lag it did
    ///   measure.
    public init(clock: any MonotonicClock, settlingWindow: Duration = .milliseconds(500)) {
        self.clock = clock
        self.settlingWindow = settlingWindow
        state = OSAllocatedUnfairLock(
            initialState: State(synthesizer: ScreenStateSynthesizer(initial: ScreenStateMapping.current()))
        )
        let (stream, continuation) = AsyncStream<Timestamped<ScreenState>>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation

        let distributed = DistributedNotificationCenter.default()
        observers.add(distributed, name: Self.screenIsLocked) { [weak self] in self?.signal(.lockedNotification) }
        observers.add(distributed, name: Self.screenIsUnlocked) { [weak self] in self?.signal(.unlockedNotification) }

        let workspace = NSWorkspaceNotifications.center
        observers.add(workspace, name: NSWorkspaceNotifications.screensDidSleep) { [weak self] in
            self?.signal(.screensDidSleep)
        }
        observers.add(workspace, name: NSWorkspaceNotifications.screensDidWake) { [weak self] in
            self?.signal(.screensDidWake)
        }
    }

    deinit {
        observers.removeAll()
        continuation.finish()
    }

    public var current: ScreenState { ScreenStateMapping.current() }

    public var changes: AsyncStream<Timestamped<ScreenState>> { stream }

    // MARK: - Signal handling

    private func signal(_ signal: ScreenStateSynthesizer.Signal) {
        let query = ScreenStateMapping.current()
        let (step, generation) = state.withLock { state -> (ScreenStateSynthesizer.Step, UInt64) in
            state.generation &+= 1
            return (state.synthesizer.handle(signal, query: query), state.generation)
        }
        switch step {
        case .unchanged:
            break
        case .report(let value):
            yield(value)
        case .settle(let expecting):
            settle(expecting: expecting, generation: generation)
        }
    }

    private func settle(expecting: ScreenState, generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: settlingWindow)
            } catch {
                // Cancelled while waiting: abandon this settling attempt rather than report a value
                // that was never confirmed.
                return
            }
            let query = ScreenStateMapping.current()
            let step = state.withLock { state -> ScreenStateSynthesizer.Step? in
                guard state.generation == generation else { return nil }
                return state.synthesizer.settled(expecting: expecting, query: query)
            }
            if case .report(let value) = step { yield(value) }
        }
    }

    private func yield(_ value: ScreenState) {
        continuation.yield(Timestamped(value, at: clock.now()))
    }

    // MARK: - Undocumented signal names (ADR-004)

    private static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}
