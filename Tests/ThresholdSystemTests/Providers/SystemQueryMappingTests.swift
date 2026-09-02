import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// L4 mapping + fail-closed tests: the raw system snapshots are turned into Domain states by pure
/// functions, so the mapping is covered without a real device (docs/specs/testing.md §1, L4).
@Suite struct ScreenStateMappingTests {
    private let key = ScreenStateMapping.lockedKey

    @Test func absentKeyMeansUnlocked() {
        // SPIKE-001: the key is absent, not zero, while the screen is unlocked.
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [:]) == .unlocked)
    }

    @Test func oneMeansLocked() {
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [key: 1]) == .locked)
    }

    @Test func zeroMeansUnlocked() {
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [key: 0]) == .unlocked)
    }

    @Test func booleanValuesAreAccepted() {
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [key: true]) == .locked)
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [key: false]) == .unlocked)
    }

    @Test func missingDictionaryIsUnknown() {
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: nil) == .unknown)
    }

    @Test func unrecognisedValueIsUnknown() {
        #expect(ScreenStateMapping.screenState(fromSessionDictionary: [key: "locked"]) == .unknown)
    }
}

@Suite struct SessionStateMappingTests {
    private let key = SessionStateMapping.onConsoleKey

    @Test func onConsoleMeansActive() {
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [key: 1]) == .active)
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [key: true]) == .active)
    }

    @Test func offConsoleMeansInactive() {
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [key: 0]) == .inactive)
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [key: false]) == .inactive)
    }

    @Test func missingKeyIsUnknown() {
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [:]) == .unknown)
    }

    @Test func missingDictionaryIsUnknown() {
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: nil) == .unknown)
    }

    @Test func unrecognisedValueIsUnknown() {
        #expect(SessionStateMapping.sessionState(fromSessionDictionary: [key: "yes"]) == .unknown)
    }
}

@Suite struct PowerStateMappingTests {
    @Test func systemSleepAndWake() {
        #expect(PowerStateMapping.state(for: .willSleep) == .systemAsleep)
        #expect(PowerStateMapping.state(for: .didWake) == .awake)
    }

    @Test func displaySleepAndWake() {
        #expect(PowerStateMapping.state(for: .screensDidSleep) == .displayAsleep)
        #expect(PowerStateMapping.state(for: .screensDidWake) == .awake)
    }

    @Test func displayQueryMapping() {
        #expect(PowerStateMapping.state(displayIsAsleep: true) == .displayAsleep)
        #expect(PowerStateMapping.state(displayIsAsleep: false) == .awake)
    }
}
