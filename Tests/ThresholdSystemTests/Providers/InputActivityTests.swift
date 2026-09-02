import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// SPIKE-008 is a CONDITIONAL GO: `.hidSystemState` is trustworthy on an unlocked, active console
/// session and meaningless anywhere else, so `inputIdle` must be `nil` outside those conditions
/// (docs/spikes/SPIKE-008-input-idle-detection.md, security.md §2 rule 3).
@Suite struct InputActivityGateTests {
    @Test func disabledNeverSamples() {
        #expect(InputActivityGate.shouldSample(isEnabled: false, session: .active, screen: .unlocked) == false)
    }

    @Test func enabledSamplesOnlyOnAnUnlockedConsoleSession() {
        #expect(InputActivityGate.shouldSample(isEnabled: true, session: .active, screen: .unlocked))
    }

    /// A keystroke at the lock screen does not reset `.hidSystemState`, so a reading taken there
    /// describes nothing the user just did.
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

    @Test func samplingIsOnByDefault() {
        // Compared against an explicitly enabled provider rather than asserted non-nil, so the test
        // states the default without also asserting that this machine has a readable event source.
        let byDefault = MacOSInputActivityProvider(
            session: FakeSessionStateProvider(initial: .active),
            screen: FakeScreenStateProvider(initial: .unlocked)
        ).current
        let explicitlyEnabled = provider(enabled: true, session: .active, screen: .unlocked).current
        #expect((byDefault == nil) == (explicitlyEnabled == nil))
    }

    @Test func theToggleStillTurnsSamplingOff() {
        #expect(provider(enabled: false, session: .active, screen: .unlocked).current == nil)
    }

    @Test func gatedOffReturnsNil() {
        #expect(provider(enabled: false, session: .active, screen: .unlocked).current == nil)
        #expect(provider(enabled: true, session: .unknown, screen: .unlocked).current == nil)
        #expect(provider(enabled: true, session: .active, screen: .locked).current == nil)
    }

    @Test func anIdleSampleIsNeverNegative() {
        // Whether a headless CI session has an event source at all is not this target's contract;
        // the contract is that an unusable reading becomes `nil` rather than a bogus number.
        guard let idle = provider(enabled: true, session: .active, screen: .unlocked).current else { return }
        #expect(idle >= .zero)
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
