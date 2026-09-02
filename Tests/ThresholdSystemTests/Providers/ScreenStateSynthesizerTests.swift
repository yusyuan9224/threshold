import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// L4 mapping tests for the pure part of `ScreenStateProviding` (docs/specs/testing.md §1).
///
/// SPIKE-001 (2026-09-02, n=4) measured that `CGSSessionScreenIsLocked` has already flipped by the
/// time `com.apple.screenIsLocked` / `screenIsUnlocked` arrives, 10-110 ms later, and never observed
/// a mismatch. The synthesizer therefore treats the query as authoritative and only falls back to a
/// settling window when the two sources disagree.
@Suite struct ScreenStateSynthesizerTests {
    @Test func agreeingLockNotificationReportsLocked() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        #expect(s.handle(.lockedNotification, query: .locked) == .report(.locked))
        #expect(s.reported == .locked)
    }

    @Test func agreeingUnlockNotificationReportsUnlocked() {
        var s = ScreenStateSynthesizer(initial: .locked)
        #expect(s.handle(.unlockedNotification, query: .unlocked) == .report(.unlocked))
        #expect(s.reported == .unlocked)
    }

    @Test func repeatedAgreeingNotificationIsNotReportedTwice() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        #expect(s.handle(.lockedNotification, query: .locked) == .report(.locked))
        #expect(s.handle(.lockedNotification, query: .locked) == .unchanged)
    }

    @Test func disagreeingLockNotificationAsksToSettle() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        #expect(s.handle(.lockedNotification, query: .unlocked) == .settle(expecting: .locked))
        #expect(s.reported == .unlocked, "nothing is reported until the settling window resolves")
    }

    @Test func unavailableQueryOnNotificationAsksToSettle() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        #expect(s.handle(.unlockedNotification, query: .unknown) == .settle(expecting: .unlocked))
    }

    @Test func settlingWithAgreementReportsTheQueryValue() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        _ = s.handle(.lockedNotification, query: .unlocked)
        #expect(s.settled(expecting: .locked, query: .locked) == .report(.locked))
        #expect(s.reported == .locked)
    }

    @Test func settlingWithPersistentDisagreementReportsUnknown() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        _ = s.handle(.lockedNotification, query: .unlocked)
        #expect(s.settled(expecting: .locked, query: .unlocked) == .report(.unknown))
        #expect(s.reported == .unknown, "fail closed: two sources that will not agree are not evidence")
    }

    @Test func settlingWithUnavailableQueryReportsUnknown() {
        var s = ScreenStateSynthesizer(initial: .locked)
        _ = s.handle(.unlockedNotification, query: .unknown)
        #expect(s.settled(expecting: .unlocked, query: .unknown) == .report(.unknown))
    }

    @Test func screensSleepAndWakeAdoptTheQueryDirectly() {
        var s = ScreenStateSynthesizer(initial: .unlocked)
        #expect(s.handle(.screensDidSleep, query: .unlocked) == .unchanged)
        #expect(s.handle(.screensDidSleep, query: .locked) == .report(.locked))
        #expect(s.handle(.screensDidWake, query: .unlocked) == .report(.unlocked))
    }

    @Test func screensSignalWithUnavailableQueryReportsUnknown() {
        var s = ScreenStateSynthesizer(initial: .locked)
        #expect(s.handle(.screensDidWake, query: .unknown) == .report(.unknown))
    }

    @Test func recoveryFromUnknownIsReported() {
        var s = ScreenStateSynthesizer(initial: .unknown)
        #expect(s.handle(.unlockedNotification, query: .unlocked) == .report(.unlocked))
    }
}
