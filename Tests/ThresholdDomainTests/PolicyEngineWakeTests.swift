import Testing
@testable import ThresholdDomain

/// Wake rules from proximity-domain.md §6.3.
@Suite("Policy engine — wake rule")
struct PolicyEngineWakeTests {
    private func evaluate(_ snapshot: PolicySnapshot) -> PolicyOutput {
        var engine = PolicyEngine()
        return engine.evaluate(snapshot, trigger: .presence)
    }

    /// T-16 — wake fires on the *arrival edge*.
    @Test func wakeIsProposedInsideTheWakeWindow() {
        let out = evaluate(PolicyFixture.wakeable(presenceSince: PolicyFixture.at(100), now: PolicyFixture.at(110)))
        #expect(out.isWake)
        #expect(out.action?.episode == EpisodeID(1))
        #expect(out.action?.proposedAt == PolicyFixture.at(110))
    }

    @Test func wakeIsProposedExactlyAtTheWindowBoundary() {
        let out = evaluate(PolicyFixture.wakeable(presenceSince: PolicyFixture.at(100), now: PolicyFixture.at(130)))
        #expect(out.isWake)
    }

    /// T-16 — sitting at an already-locked Mac must not flash the screen forever.
    @Test func wakeIsNotProposedOutsideTheWakeWindow() {
        let out = evaluate(PolicyFixture.wakeable(presenceSince: PolicyFixture.at(100), now: PolicyFixture.at(131)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.outsideWakeWindow))
    }

    /// T-16 — nothing to wake when the screen is already unlocked.
    @Test func wakeIsNotProposedWhenTheScreenIsUnlocked() {
        let out = evaluate(PolicyFixture.wakeable(screen: .unlocked, now: PolicyFixture.at(110)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionUnsatisfied(.screen)))
    }

    @Test func wakeRequiresDisplayAsleepPower() {
        let out = evaluate(PolicyFixture.wakeable(power: .awake, now: PolicyFixture.at(110)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionUnsatisfied(.power)))
    }

    @Test func wakeOnReturnOffDisablesWake() {
        var settings = PolicySettings()
        settings.wakeOnReturn = false
        let out = evaluate(PolicyFixture.wakeable(settings: settings, now: PolicyFixture.at(110)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.disabledBySettings))
    }

    /// T-17 (policy half) — an unarmed calibration gate blocks Wake as well as Auto Lock.
    @Test func calibrationNotArmedNeverWakes() {
        let snapshot = PolicyFixture.snapshot(
            presence: .present, presenceSince: PolicyFixture.at(100), evidence: .measuredNear,
            power: .displayAsleep, screen: .locked, calibration: .notArmed(.needsRevalidation(osMajorChanged: true)),
            inputIdle: nil, now: PolicyFixture.at(110))
        let out = evaluate(snapshot)
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionUnsatisfied(.calibration)))
    }

    @Test(arguments: [SensorHealth.degraded(.scanInterrupted), .unavailable(.poweredOff), .initializing])
    func sensorNotHealthyNeverWakes(sensor: SensorHealth) {
        let snapshot = PolicyFixture.snapshot(
            presence: .present, presenceSince: PolicyFixture.at(100), evidence: .measuredNear,
            sensor: sensor, power: .displayAsleep, screen: .locked, inputIdle: nil, now: PolicyFixture.at(110))
        let out = evaluate(snapshot)
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionIndeterminate(.sensor)))
    }

    /// Only a confirmed arrival wakes the machine; a merely plausible one does not.
    @Test(arguments: [PresenceState.departing, .away, .unknown(.initial), .unknown(.evidenceExpired)])
    func wakeRequiresPresentPresence(presence: PresenceState) {
        let snapshot = PolicyFixture.snapshot(
            presence: presence, presenceSince: PolicyFixture.at(100), evidence: .none,
            power: .displayAsleep, screen: .locked, inputIdle: nil, now: PolicyFixture.at(110))
        let out = evaluate(snapshot)
        #expect(out.action == nil)
        #expect(out.rationale.contains(.presenceUncertain))
    }

    /// T-16 — "once": re-evaluating the same arrival episode must not wake again.
    @Test func wakeHappensOnlyOncePerEpisode() {
        var engine = PolicyEngine()
        let first = engine.evaluate(PolicyFixture.wakeable(now: PolicyFixture.at(105)), trigger: .presence)
        #expect(first.isWake)
        engine.markIssued(first.action!.id, at: PolicyFixture.at(105))

        let second = engine.evaluate(PolicyFixture.wakeable(now: PolicyFixture.at(106)), trigger: .screen)
        #expect(second.action == nil)
        #expect(second.rationale.contains(.alreadyIssued(first.action!.id)))
    }

    /// Wake is never retried: an unwoken display is a nuisance, not a security hole.
    @Test func wakeIsNeverRetriedAfterRetryAfterElapses() {
        var engine = PolicyEngine()
        let first = engine.evaluate(PolicyFixture.wakeable(now: PolicyFixture.at(100)), trigger: .presence)
        #expect(first.isWake)
        engine.markIssued(first.action!.id, at: PolicyFixture.at(100))

        // Well past retryAfter (5 s) but still inside the wake window (30 s).
        let later = engine.evaluate(PolicyFixture.wakeable(now: PolicyFixture.at(125)), trigger: .deadline)
        #expect(later.action == nil)
        #expect(engine.ledger.filter { $0.kind == .wake }.count == 1)
        #expect(engine.ledger.first { $0.kind == .wake }?.attempts == 1)
    }

    /// A new arrival episode is a new opportunity to wake.
    @Test func aNewArrivalEpisodeMayWakeAgain() {
        var engine = PolicyEngine()
        let first = engine.evaluate(PolicyFixture.wakeable(episode: EpisodeID(1), now: PolicyFixture.at(105)),
                                    trigger: .presence)
        #expect(first.isWake)
        engine.markIssued(first.action!.id, at: PolicyFixture.at(105))

        let second = engine.evaluate(
            PolicyFixture.wakeable(presenceSince: PolicyFixture.at(500), episode: EpisodeID(2),
                                   now: PolicyFixture.at(505)),
            trigger: .presence)
        #expect(second.isWake)
        #expect(second.action?.episode == EpisodeID(2))
        #expect(second.action?.id != first.action?.id)
    }
}
