import ThresholdDomain

/// Production `LockControlling`: request a lock, then confirm it happened.
///
/// Confirmation is the point. A lock request is fire-and-forget at the system level, and the whole
/// product rests on the screen actually being locked, so the controller polls
/// `ScreenStateProviding` until it reports `.locked` or the timeout expires. `.unknown` never
/// counts as confirmation (security.md §2 rule 1). On timeout it throws and stops: retry and
/// give-up belong to the Policy ledger, not here (architecture.md §6).
public final class MacOSLockController: LockControlling, Sendable {
    private let strategies: [any LockStrategy]
    private let screen: any ScreenStateProviding
    private let clock: any MonotonicClock
    private let confirmTimeout: Duration
    private let pollInterval: Duration

    /// Strategy ① (IOKit, unsampled by SPIKE-007) then its `pmset` equivalent (the path SPIKE-007's
    /// two samples used). Order is a spec choice pending SPIKE-007's full run, not an evidence ranking.
    public static let defaultStrategies: [any LockStrategy] = [
        IODisplayWranglerLockStrategy(),
        PMSetDisplaySleepLockStrategy(),
    ]

    public init(
        strategies: [any LockStrategy] = MacOSLockController.defaultStrategies,
        screen: any ScreenStateProviding,
        clock: any MonotonicClock,
        confirmTimeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.strategies = strategies
        self.screen = screen
        self.clock = clock
        self.confirmTimeout = confirmTimeout
        self.pollInterval = pollInterval
    }

    public func lock(reason: LockReason) async throws {
        try await requestLock()
        try await confirmLocked()
    }

    /// Tries each strategy in order and stops at the first that accepts the request.
    private func requestLock() async throws {
        var failures: [String] = []
        for strategy in strategies {
            do {
                try await strategy.requestLock()
                return
            } catch {
                failures.append("\(strategy.name): \(error)")
            }
        }
        throw LockError.allStrategiesFailed(failures)
    }

    private func confirmLocked() async throws {
        let deadline = clock.now() + confirmTimeout
        while true {
            if screen.current == .locked { return }
            let next = clock.now() + pollInterval
            guard next <= deadline else { throw LockError.notConfirmed }
            try await clock.sleep(until: next)
        }
    }
}
