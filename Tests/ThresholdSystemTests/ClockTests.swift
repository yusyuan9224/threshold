import Foundation
import Testing
import os
import ThresholdDomain
@testable import ThresholdSystem

// MARK: - Helpers

/// Polls `condition` until it holds or `timeout` elapses. Fails the test on timeout.
///
/// Used instead of a fixed sleep so the tests stay deterministic: they wait for the *observable*
/// state (`pendingSleepers`) rather than guessing how long a task takes to reach its suspension.
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(description)")
}

/// Thread-safe append-only order recorder.
private final class Recorder: Sendable {
    private let storage = OSAllocatedUnfairLock<[Int]>(initialState: [])
    func record(_ value: Int) { storage.withLock { $0.append(value) } }
    var values: [Int] { storage.withLock { $0 } }
}

// MARK: - FakeClock

@Suite("FakeClock")
struct FakeClockTests {
    @Test func nowStartsAtTheGivenInstantAndAdvancesOnDemand() {
        let clock = FakeClock(start: MonotonicInstant(nanoseconds: 1_000))
        #expect(clock.now() == MonotonicInstant(nanoseconds: 1_000))

        clock.advance(by: .milliseconds(250))
        #expect(clock.now() == MonotonicInstant(nanoseconds: 1_000) + .milliseconds(250))

        clock.advance(to: MonotonicInstant(nanoseconds: 5_000_000_000))
        #expect(clock.now() == MonotonicInstant(nanoseconds: 5_000_000_000))
    }

    @Test func defaultStartIsZeroAndTimeNeverRunsBackwards() {
        let clock = FakeClock()
        #expect(clock.now() == .zero)

        clock.advance(by: .seconds(2))
        clock.advance(to: MonotonicInstant(nanoseconds: 1))
        #expect(clock.now() == .zero + .seconds(2))
    }

    @Test func sleepUntilPastDeadlineReturnsImmediately() async throws {
        let clock = FakeClock(start: MonotonicInstant(nanoseconds: 10_000))

        try await clock.sleep(until: MonotonicInstant(nanoseconds: 9_999))
        try await clock.sleep(until: MonotonicInstant(nanoseconds: 10_000))

        #expect(clock.pendingSleepers == 0)
        #expect(clock.now() == MonotonicInstant(nanoseconds: 10_000))
    }

    @Test func sleeperResumesOnlyAfterAdvanceCrossesTheDeadline() async throws {
        let clock = FakeClock()
        let deadline = MonotonicInstant.zero + .seconds(30)
        let finished = OSAllocatedUnfairLock(initialState: false)

        let sleeper = Task {
            try await clock.sleep(until: deadline)
            finished.withLock { $0 = true }
        }

        await waitUntil("the sleeper to suspend") { clock.pendingSleepers == 1 }

        clock.advance(by: .seconds(29))
        #expect(clock.pendingSleepers == 1)
        #expect(finished.withLock { $0 } == false)

        clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(finished.withLock { $0 })
        #expect(clock.pendingSleepers == 0)
    }

    /// Sleepers registered out of order still wake in deadline order.
    ///
    /// Asserted one deadline at a time: which sleepers the clock has released is deterministic,
    /// whereas the order in which already-released tasks get scheduled is the runtime's choice.
    @Test func multipleSleepersResumeInDeadlineOrder() async throws {
        let clock = FakeClock()
        let recorder = Recorder()

        // Registered out of deadline order on purpose.
        let third = Task { try await clock.sleep(until: .zero + .seconds(3)); recorder.record(3) }
        let first = Task { try await clock.sleep(until: .zero + .seconds(1)); recorder.record(1) }
        let second = Task { try await clock.sleep(until: .zero + .seconds(2)); recorder.record(2) }

        await waitUntil("all three sleepers to suspend") { clock.pendingSleepers == 3 }

        clock.advance(to: .zero + .seconds(1))
        try await first.value
        #expect(recorder.values == [1])
        #expect(clock.pendingSleepers == 2)

        clock.advance(to: .zero + .seconds(2))
        try await second.value
        #expect(recorder.values == [1, 2])
        #expect(clock.pendingSleepers == 1)

        clock.advance(to: .zero + .seconds(3))
        try await third.value
        #expect(recorder.values == [1, 2, 3])
        #expect(clock.pendingSleepers == 0)
    }

    @Test func advanceWakesOnlySleepersWhoseDeadlineHasPassed() async throws {
        let clock = FakeClock()
        let early = Task { try await clock.sleep(until: .zero + .milliseconds(100)) }
        let late = Task { try await clock.sleep(until: .zero + .seconds(10)) }

        await waitUntil("both sleepers to suspend") { clock.pendingSleepers == 2 }

        clock.advance(by: .milliseconds(100))
        try await early.value
        #expect(clock.pendingSleepers == 1)

        clock.advance(by: .seconds(10))
        try await late.value
        #expect(clock.pendingSleepers == 0)
    }

    @Test func cancellationThrowsAndDropsTheSleeper() async throws {
        let clock = FakeClock()
        let sleeper = Task { try await clock.sleep(until: .zero + .seconds(3_600)) }

        await waitUntil("the sleeper to suspend") { clock.pendingSleepers == 1 }
        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingSleepers == 0)

        // The clock stays usable after a cancellation.
        clock.advance(by: .seconds(1))
        #expect(clock.now() == .zero + .seconds(1))
    }

    @Test func cancellationBeforeSuspensionAlsoThrows() async throws {
        let clock = FakeClock()
        let sleeper = Task {
            // Give the cancellation a chance to land before `sleep(until:)` registers.
            await Task.yield()
            try await clock.sleep(until: .zero + .seconds(3_600))
        }
        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.pendingSleepers == 0)
    }

    @Test func concurrentSleepersAllResumeOnASingleAdvance() async throws {
        let clock = FakeClock()
        let count = 64

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await clock.sleep(until: .zero + .milliseconds(index + 1))
                }
            }
            await waitUntil("all \(count) sleepers to suspend") { clock.pendingSleepers == count }
            clock.advance(by: .seconds(1))
            try await group.waitForAll()
        }

        #expect(clock.pendingSleepers == 0)
    }

    @Test func sleepForConvenienceMeasuresFromTheCurrentInstant() async throws {
        let clock = FakeClock(start: MonotonicInstant(nanoseconds: 500))
        let sleeper = Task { try await clock.sleep(for: .milliseconds(10)) }

        await waitUntil("the sleeper to suspend") { clock.pendingSleepers == 1 }

        clock.advance(by: .milliseconds(9))
        #expect(clock.pendingSleepers == 1)

        clock.advance(by: .milliseconds(1))
        try await sleeper.value
        #expect(clock.pendingSleepers == 0)
    }
}

// MARK: - ContinuousMonotonicClock

@Suite("ContinuousMonotonicClock")
struct ContinuousMonotonicClockTests {
    @Test func nowIsMonotonicNonDecreasingAcrossCalls() {
        let clock = ContinuousMonotonicClock()
        var previous = clock.now()
        for _ in 0..<1_000 {
            let current = clock.now()
            #expect(current >= previous)
            previous = current
        }
    }

    @Test func sleepForElapsesAtLeastTheRequestedDuration() async throws {
        let clock = ContinuousMonotonicClock()
        let start = clock.now()
        try await clock.sleep(for: .milliseconds(20))
        #expect(clock.now() - start >= .milliseconds(20))
    }

    @Test func sleepUntilPastDeadlineReturnsImmediately() async throws {
        let clock = ContinuousMonotonicClock()
        let start = clock.now()
        try await clock.sleep(until: start - .seconds(5))
        #expect(clock.now() - start < .milliseconds(500))
    }
}
