import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// SPIKE-008 has not run, so `inputIdle` must be `nil` unless a build explicitly opts in and the
/// session is demonstrably the console session with an unlocked screen
/// (docs/specs/system-integration.md §1, security.md §2 rule 3).
@Suite struct InputActivityGateTests {
    @Test func disabledNeverSamples() {
        #expect(InputActivityGate.shouldSample(isEnabled: false, session: .active, screen: .unlocked) == false)
    }

    @Test func enabledSamplesOnlyOnAnUnlockedConsoleSession() {
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .active, screen: .unlocked))
    }

    @Test func lockedOrUnknownScreenBlocksSampling() {
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .active, screen: .locked) == false)
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .active, screen: .unknown) == false)
    }

    @Test func inactiveOrUnknownSessionBlocksSampling() {
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .inactive, screen: .unlocked) == false)
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .unknown, screen: .unlocked) == false)
    }
}

@Suite struct MacOSInputActivityProviderTests {
    private func provider(enabled: Bool, session: SessionState, screen: ScreenState) -> MacOSInputActivityProvider {
        MacOSInputActivityProvider(
            session: FakeSessionStateProvider(initial: session),
            screen: FakeScreenStateProvider(initial: screen),
            isEnabled: enabled
        )
    }

    @Test func defaultsToDisabled() {
        let p = MacOSInputActivityProvider(
            session: FakeSessionStateProvider(initial: .active),
            screen: FakeScreenStateProvider(initial: .unlocked)
        )
        #expect(p.current == nil)
    }

    @Test func gatedOffReturnsNil() {
        #expect(provider(enabled: false, session: .active, screen: .unlocked).current == nil)
        #expect(provider(enabled: true, session: .unknown, screen: .unlocked).current == nil)
        #expect(provider(enabled: true, session: .active, screen: .locked).current == nil)
    }

    @Test func enabledOnConsoleReportsANonNegativeIdleDuration() {
        let idle = provider(enabled: true, session: .active, screen: .unlocked).current
        #expect(idle != nil)
        #expect((idle ?? .zero) >= .zero)
    }
}

@Suite struct FakeInputActivityProviderTests {
    @Test func reportsWhateverTheTestSets() {
        let p = FakeInputActivityProvider()
        #expect(p.current == nil, "the conservative default matches the pre-SPIKE-008 contract")
        p.set(.seconds(42))
        #expect(p.current == .seconds(42))
        p.set(nil)
        #expect(p.current == nil)
    }
}
