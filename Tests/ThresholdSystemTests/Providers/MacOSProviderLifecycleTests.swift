import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// Lifecycle smoke tests for the macOS providers: they register distributed and workspace observers
/// in `init` and remove them in `deinit`, and a mistake there is a crash rather than a wrong value.
///
/// This is deliberately not a test of real screen or power behaviour, which testing.md §1 leaves to
/// the on-device spike checklists.
@Suite struct MacOSProviderLifecycleTests {
    @Test func providersConstructAndTearDownCleanly() {
        let clock = FakeClock()
        for _ in 0 ..< 3 {
            let screen = MacOSScreenStateProvider(clock: clock)
            let session = MacOSSessionStateProvider(clock: clock)
            let power = MacOSPowerStateProvider(clock: clock)
            _ = screen.current
            _ = session.current
            _ = power.current
        }
        #expect(clock.pendingSleepers == 0, "a provider must not leave a settling task suspended")
    }

    @Test func aRunningProcessIsNeverReportedAsSystemAsleep() {
        // The process is frozen for the whole of system sleep, so observing `.systemAsleep` from
        // inside a running test would mean the notification memory had outlived the wake it
        // describes.
        #expect(MacOSPowerStateProvider(clock: FakeClock()).current != .systemAsleep)
    }

    @Test func sessionProviderAgreesWithTheLiveQuery() {
        let provider = MacOSSessionStateProvider(clock: FakeClock())
        #expect(provider.current == SessionStateMapping.sessionState(fromSessionDictionary: SystemSessionQuery.dictionary()))
    }

    @Test func screenProviderAgreesWithTheLiveQuery() {
        let provider = MacOSScreenStateProvider(clock: FakeClock())
        #expect(provider.current == ScreenStateMapping.screenState(fromSessionDictionary: SystemSessionQuery.dictionary()))
    }
}
