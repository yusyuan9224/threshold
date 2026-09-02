import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// Every Fake must be able to report `.unknown` and to drive its stream from a test
/// (docs/specs/system-integration.md preamble; testing.md §1, L3).
@Suite struct FakeProviderTests {
    @Test func screenFakeStartsUnknownAndPushesTimestampedChanges() async {
        let fake = FakeScreenStateProvider()
        #expect(fake.current == .unknown)

        var iterator = fake.changes.makeAsyncIterator()
        fake.push(.locked, at: MonotonicInstant(nanoseconds: 7))
        let first = await iterator.next()
        #expect(first == Timestamped(.locked, at: MonotonicInstant(nanoseconds: 7)))
        #expect(fake.current == .locked)
    }

    @Test func screenFakeCanChangeCurrentWithoutEmitting() async {
        let fake = FakeScreenStateProvider(initial: .unlocked)
        fake.set(.unknown)
        #expect(fake.current == .unknown)

        var iterator = fake.changes.makeAsyncIterator()
        fake.push(.locked, at: .zero)
        #expect(await iterator.next() == Timestamped(.locked, at: .zero))
    }

    @Test func sessionFakeCarriesUnknown() async {
        let fake = FakeSessionStateProvider(initial: .active)
        var iterator = fake.changes.makeAsyncIterator()
        fake.push(.unknown, at: .zero)
        #expect(await iterator.next() == Timestamped(.unknown, at: .zero))
        #expect(fake.current == .unknown)
    }

    @Test func powerFakeCarriesEveryState() async {
        let fake = FakePowerStateProvider(initial: .awake)
        var iterator = fake.changes.makeAsyncIterator()
        for state in [PowerState.displayAsleep, .systemAsleep, .awake, .unknown] {
            fake.push(state, at: .zero)
            #expect(await iterator.next() == Timestamped(state, at: .zero))
        }
        #expect(fake.current == .unknown)
    }

    @Test func finishingEndsTheStream() async {
        let fake = FakeScreenStateProvider()
        var iterator = fake.changes.makeAsyncIterator()
        fake.finish()
        #expect(await iterator.next() == nil)
    }
}
