import Testing
@testable import ThresholdDomain

/// `RequiredPreconditions.check(for:)` — the fail-closed gate in front of every action
/// (security.md §2.1, proximity-domain.md §6.1).
@Suite("Policy preconditions")
struct PolicyPreconditionsTests {
    private func p(
        sensor: SensorHealth = .healthy,
        session: SessionState = .active,
        power: PowerState = .awake,
        screen: ScreenState = .unlocked,
        calibration: CalibrationGate = .armed(PolicyFixture.profile)
    ) -> RequiredPreconditions {
        PolicyFixture.preconditions(sensor: sensor, session: session, power: power, screen: screen, calibration: calibration)
    }

    private let anyLock = ActionKind.lock(.evidenceExpired)

    @Test func lockIsSatisfiedWhenAwakeAndUnlocked() {
        #expect(p().check(for: anyLock) == .satisfied)
    }

    @Test func wakeIsSatisfiedWhenDisplayAsleepAndLocked() {
        #expect(p(power: .displayAsleep, screen: .locked).check(for: .wake) == .satisfied)
    }

    /// The lock reason never changes the gate — only the kind does.
    @Test(arguments: [LockReason.evidenceExpired, .userDeparted(.measuredFar), .userDeparted(.departureThenSilent)])
    func lockReasonDoesNotAffectTheGate(reason: LockReason) {
        #expect(p().check(for: .lock(reason)) == .satisfied)
        #expect(p(screen: .unknown).check(for: .lock(reason)) == .indeterminate(.screen))
    }

    // MARK: sensor

    /// T-12 — a sensor that is not healthy means we cannot trust *any* belief about the
    /// user, so it is indeterminate rather than a definite "no" (ADR-008).
    @Test(arguments: [
        SensorHealth.initializing,
        .degraded(.resetting),
        .degraded(.scanInterrupted),
        .unavailable(.poweredOff),
        .unavailable(.unauthorized),
        .unavailable(.unsupported),
        .unavailable(.scannerFailed),
    ])
    func sensorNotHealthyIsIndeterminate(sensor: SensorHealth) {
        #expect(p(sensor: sensor).check(for: anyLock) == .indeterminate(.sensor))
        #expect(p(sensor: sensor, power: .displayAsleep, screen: .locked).check(for: .wake) == .indeterminate(.sensor))
    }

    // MARK: session

    @Test func sessionUnknownIsIndeterminate() {
        #expect(p(session: .unknown).check(for: anyLock) == .indeterminate(.session))
    }

    /// A background session is a definite, known-wrong state, not a missing reading.
    @Test func sessionInactiveIsUnsatisfied() {
        #expect(p(session: .inactive).check(for: anyLock) == .unsatisfied(.session))
    }

    // MARK: power

    @Test func powerUnknownIsIndeterminate() {
        #expect(p(power: .unknown).check(for: anyLock) == .indeterminate(.power))
        #expect(p(power: .unknown, screen: .locked).check(for: .wake) == .indeterminate(.power))
    }

    @Test func lockRequiresAwakePower() {
        #expect(p(power: .displayAsleep).check(for: anyLock) == .unsatisfied(.power))
        #expect(p(power: .systemAsleep).check(for: anyLock) == .unsatisfied(.power))
    }

    @Test func wakeRequiresDisplayAsleepPower() {
        #expect(p(power: .awake, screen: .locked).check(for: .wake) == .unsatisfied(.power))
        #expect(p(power: .systemAsleep, screen: .locked).check(for: .wake) == .unsatisfied(.power))
    }

    // MARK: screen

    /// T-06 — `unknown` screen state is never guessed at.
    @Test func screenUnknownIsIndeterminate() {
        #expect(p(screen: .unknown).check(for: anyLock) == .indeterminate(.screen))
        #expect(p(power: .displayAsleep, screen: .unknown).check(for: .wake) == .indeterminate(.screen))
    }

    @Test func lockRequiresUnlockedScreen() {
        #expect(p(screen: .locked).check(for: anyLock) == .unsatisfied(.screen))
    }

    @Test func wakeRequiresLockedScreen() {
        #expect(p(power: .displayAsleep, screen: .unlocked).check(for: .wake) == .unsatisfied(.screen))
    }

    // MARK: calibration

    /// T-17 — not armed is a definite "no": we know the profile is unusable.
    @Test(arguments: [
        NotArmedReason.noProfile,
        .deviceMismatch,
        .macMismatch,
        .needsRevalidation(osMajorChanged: true),
        .driftExceeded,
        .invalid(.overlap),
    ])
    func calibrationNotArmedIsUnsatisfied(reason: NotArmedReason) {
        #expect(p(calibration: .notArmed(reason)).check(for: anyLock) == .unsatisfied(.calibration))
        #expect(p(power: .displayAsleep, screen: .locked, calibration: .notArmed(reason)).check(for: .wake)
                == .unsatisfied(.calibration))
    }

    // MARK: ordering

    /// Fields are reported in a fixed order — sensor, session, power, screen, calibration —
    /// so a snapshot with several problems always yields the same diagnosis.
    @Test func firstFailingFieldWinsInDeclaredOrder() {
        let allBad = p(sensor: .unavailable(.poweredOff), session: .inactive, power: .unknown,
                       screen: .unknown, calibration: .notArmed(.noProfile))
        #expect(allBad.check(for: anyLock) == .indeterminate(.sensor))

        let fromSession = p(session: .inactive, power: .unknown, screen: .unknown, calibration: .notArmed(.noProfile))
        #expect(fromSession.check(for: anyLock) == .unsatisfied(.session))

        let fromPower = p(power: .unknown, screen: .unknown, calibration: .notArmed(.noProfile))
        #expect(fromPower.check(for: anyLock) == .indeterminate(.power))

        let fromScreen = p(screen: .unknown, calibration: .notArmed(.noProfile))
        #expect(fromScreen.check(for: anyLock) == .indeterminate(.screen))

        let fromCalibration = p(calibration: .notArmed(.noProfile))
        #expect(fromCalibration.check(for: anyLock) == .unsatisfied(.calibration))
    }
}
