import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// A `LockStrategy` a test drives: it records its calls and can be told to refuse.
private final class StubLockStrategy: LockStrategy, @unchecked Sendable {
    // Invariant: `calls` and `failure` are only touched from the single test task that owns this
    // stub; the controller awaits `requestLock()` before doing anything else, so there is no
    // concurrent access.
    let name: String
    private(set) var calls = 0
    var failure: (any Error)?

    init(name: String, failure: (any Error)? = nil) {
        self.name = name
        self.failure = failure
    }

    func requestLock() async throws {
        calls += 1
        if let failure { throw failure }
    }
}

/// Spins until the controller has actually suspended on the fake clock, so a test never advances
/// time into a task that has not reached its sleep yet.
private func waitForSleeper(on clock: FakeClock, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0 ..< 10_000 {
        if clock.pendingSleepers >= count { return }
        await Task.yield()
    }
    Issue.record("the controller never suspended on the clock", sourceLocation: sourceLocation)
}

@Suite struct MacOSLockControllerTests {
    private func controller(
        strategies: [any LockStrategy],
        screen: FakeScreenStateProvider,
        clock: FakeClock
    ) -> MacOSLockController {
        MacOSLockController(
            strategies: strategies,
            screen: screen,
            clock: clock,
            confirmTimeout: .seconds(3),
            pollInterval: .milliseconds(100)
        )
    }

    @Test func confirmsImmediatelyWhenTheScreenIsAlreadyLocked() async throws {
        let strategy = StubLockStrategy(name: "stub")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .locked)

        try await controller(strategies: [strategy], screen: screen, clock: clock)
            .lock(reason: .evidenceExpired)

        #expect(strategy.calls == 1)
        #expect(clock.pendingSleepers == 0)
    }

    @Test func confirmsWhenTheScreenLocksInsideTheConfirmationWindow() async throws {
        let strategy = StubLockStrategy(name: "stub")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .unlocked)
        let controller = controller(strategies: [strategy], screen: screen, clock: clock)

        let task = Task { try await controller.lock(reason: .evidenceExpired) }
        await waitForSleeper(on: clock)
        screen.set(.locked)
        clock.advance(by: .milliseconds(100))

        try await task.value
        #expect(strategy.calls == 1)
    }

    @Test func throwsNotConfirmedWhenTheScreenNeverLocks() async throws {
        let strategy = StubLockStrategy(name: "stub")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .unlocked)
        let controller = controller(strategies: [strategy], screen: screen, clock: clock)

        let task = Task { try await controller.lock(reason: .evidenceExpired) }
        await waitForSleeper(on: clock)
        clock.advance(by: .seconds(3))

        await #expect(throws: LockError.notConfirmed) { try await task.value }
    }

    @Test func anUnknownScreenStateIsNotAConfirmation() async throws {
        let strategy = StubLockStrategy(name: "stub")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .unknown)
        let controller = controller(strategies: [strategy], screen: screen, clock: clock)

        let task = Task { try await controller.lock(reason: .evidenceExpired) }
        await waitForSleeper(on: clock)
        clock.advance(by: .seconds(3))

        await #expect(throws: LockError.notConfirmed) { try await task.value }
    }

    @Test func fallsBackToTheNextStrategyWhenTheFirstIsUnavailable() async throws {
        let first = StubLockStrategy(name: "ioRequestIdle", failure: LockStrategyError.unavailable("absent"))
        let second = StubLockStrategy(name: "pmset")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .locked)

        try await controller(strategies: [first, second], screen: screen, clock: clock)
            .lock(reason: .evidenceExpired)

        #expect(first.calls == 1)
        #expect(second.calls == 1)
    }

    @Test func laterStrategiesAreNotTriedOnceOneSucceeds() async throws {
        let first = StubLockStrategy(name: "ioRequestIdle")
        let second = StubLockStrategy(name: "pmset")
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .locked)

        try await controller(strategies: [first, second], screen: screen, clock: clock)
            .lock(reason: .evidenceExpired)

        #expect(first.calls == 1)
        #expect(second.calls == 0)
    }

    @Test func reportsEveryStrategyThatFailed() async throws {
        let first = StubLockStrategy(name: "ioRequestIdle", failure: LockStrategyError.unavailable("absent"))
        let second = StubLockStrategy(name: "pmset", failure: LockStrategyError.failed("exit 1"))
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .unlocked)
        let controller = controller(strategies: [first, second], screen: screen, clock: clock)

        await #expect(throws: LockError.self) { try await controller.lock(reason: .evidenceExpired) }
        do {
            try await controller.lock(reason: .evidenceExpired)
        } catch let error as LockError {
            guard case .allStrategiesFailed(let failures) = error else {
                Issue.record("expected .allStrategiesFailed, got \(error)")
                return
            }
            #expect(failures.count == 2)
            #expect(failures[0].contains("ioRequestIdle"))
            #expect(failures[1].contains("pmset"))
        }
    }

    @Test func noStrategyAtAllFailsWithoutTouchingTheScreen() async throws {
        let clock = FakeClock()
        let screen = FakeScreenStateProvider(initial: .unlocked)
        let controller = controller(strategies: [], screen: screen, clock: clock)

        await #expect(throws: LockError.allStrategiesFailed([])) {
            try await controller.lock(reason: .evidenceExpired)
        }
    }
}

@Suite struct SpyLockControllerTests {
    @Test func recordsEveryReasonInOrder() async throws {
        let spy = SpyLockController()
        try await spy.lock(reason: .evidenceExpired)
        try await spy.lock(reason: .evidenceExpired)
        #expect(spy.lockCount == 2)
        #expect(spy.reasons == [.evidenceExpired, .evidenceExpired])
    }

    @Test func canBeToldToFailAndThenToSucceed() async throws {
        let spy = SpyLockController(failure: .notConfirmed)
        await #expect(throws: LockError.notConfirmed) { try await spy.lock(reason: .evidenceExpired) }
        #expect(spy.lockCount == 1, "a failed attempt is still an attempt")

        spy.stopFailing()
        try await spy.lock(reason: .evidenceExpired)
        #expect(spy.lockCount == 2)
    }
}
