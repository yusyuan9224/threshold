import ThresholdDomain

/// Turns the two screen-state sources into a single reported `ScreenState`.
///
/// The two sources are not equivalent. `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` are
/// *transition* signals; `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` is a *state*
/// query. SPIKE-001 (2026-09-02, n = 4 lock/unlock events) measured that the query has already
/// flipped by the time the notification arrives, 10-110 ms later, and observed no mismatch at all.
///
/// So the query is authoritative and the notification is only a cue to re-read it. The
/// "both sources must agree or report `.unknown`" hypothesis in system-integration.md §1 is kept,
/// but only as the *disagreement* path: a notification whose direction the query does not confirm
/// starts a settling window instead of immediately poisoning the state with `.unknown`, which would
/// otherwise stall Policy for as long as the mismatch lasts.
///
/// This type is pure and holds no system state, so the whole rule is covered by L4 mapping tests
/// without a real device (docs/specs/testing.md §1).
public struct ScreenStateSynthesizer: Sendable, Equatable {
    /// A cue to re-read the query. Named for the signal, not for the state it implies.
    public enum Signal: Sendable, Equatable {
        /// `com.apple.screenIsLocked`.
        case lockedNotification
        /// `com.apple.screenIsUnlocked`.
        case unlockedNotification
        /// `NSWorkspace.screensDidSleepNotification`.
        case screensDidSleep
        /// `NSWorkspace.screensDidWakeNotification`.
        case screensDidWake
    }

    /// What the provider should do with a signal.
    public enum Step: Sendable, Equatable {
        /// Emit this value on `changes`.
        case report(ScreenState)
        /// The sources agree with what was already reported; emit nothing.
        case unchanged
        /// The notification and the query disagree. Wait out the settling window, re-query, and
        /// call `settled(expecting:query:)` with the result.
        case settle(expecting: ScreenState)
    }

    /// The most recent value handed to the consumer.
    public private(set) var reported: ScreenState

    public init(initial: ScreenState) {
        reported = initial
    }

    public mutating func handle(_ signal: Signal, query: ScreenState) -> Step {
        switch signal {
        case .lockedNotification:
            return confirm(expecting: .locked, query: query)
        case .unlockedNotification:
            return confirm(expecting: .unlocked, query: query)
        case .screensDidSleep, .screensDidWake:
            // Display sleep is not a lock: it may or may not be followed by one, depending on the
            // user's "require password after sleep" setting (SPIKE-007 measured ~80 ms with
            // "immediately"). There is no expected direction to confirm, so the query stands alone.
            return adopt(query)
        }
    }

    /// Resolves a `settle` step with a query sample taken after the settling window.
    public mutating func settled(expecting: ScreenState, query: ScreenState) -> Step {
        // Still disagreeing after the window: neither source can be trusted, so fail closed.
        adopt(query == expecting ? query : .unknown)
    }

    private mutating func confirm(expecting: ScreenState, query: ScreenState) -> Step {
        query == expecting ? adopt(query) : .settle(expecting: expecting)
    }

    private mutating func adopt(_ state: ScreenState) -> Step {
        guard state != reported else { return .unchanged }
        reported = state
        return .report(state)
    }
}
