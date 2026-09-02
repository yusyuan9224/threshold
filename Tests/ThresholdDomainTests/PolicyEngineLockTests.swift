import Testing
@testable import ThresholdDomain

/// Lock rules from proximity-domain.md §6.3.
@Suite("Policy engine — lock rules")
struct PolicyEngineLockTests {
    private func evaluate(_ snapshot: PolicySnapshot, trigger: PolicyTrigger = .presence) -> PolicyOutput {
        var engine = PolicyEngine()
        return engine.evaluate(snapshot, trigger: trigger)
    }

    // MARK: measuredFar

    @Test func awayWithMeasuredFarProposesLock() {
        let out = evaluate(PolicyFixture.lockable(evidence: .measuredFar))
        #expect(out.lockReason == .userDeparted(.measuredFar))
        #expect(out.action?.episode == EpisodeID(1))
        #expect(out.action?.proposedAt == PolicyFixture.at(100))
        #expect(out.rationale.contains(.proposed(out.action!.id)))
    }

    /// T-11 — locking is the safe direction, so unknown input idle does not block a
    /// *measured* departure (security.md §2.7).
    @Test func measuredFarLocksWhenInputIdleIsUnknown() {
        let out = evaluate(PolicyFixture.lockable(evidence: .measuredFar, inputIdle: nil))
        #expect(out.lockReason == .userDeparted(.measuredFar))
    }

    @Test func measuredFarDefersWhileTheUserIsStillTyping() {
        let out = evaluate(PolicyFixture.lockable(evidence: .measuredFar, inputIdle: .seconds(3)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.userActive))
    }

    @Test func measuredFarLocksOnceIdleReachesTheGuard() {
        var settings = PolicySettings()
        settings.departedIdleGuard = .seconds(15)
        let out = evaluate(PolicyFixture.lockable(evidence: .measuredFar, inputIdle: .seconds(15), settings: settings))
        #expect(out.lockReason == .userDeparted(.measuredFar))
    }

    // MARK: departureThenSilent

    @Test func departureThenSilentProposesLockWhenEnabled() {
        let out = evaluate(PolicyFixture.lockable(evidence: .departureThenSilent))
        #expect(out.lockReason == .userDeparted(.departureThenSilent))
    }

    /// T-14 (policy half) — the independent switch suppresses this evidence class only.
    @Test func departureThenSilentIsSuppressedWhenItsSettingIsOff() {
        var settings = PolicySettings()
        settings.lockOnDepartureThenSilent = false
        let out = evaluate(PolicyFixture.lockable(evidence: .departureThenSilent, settings: settings))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.disabledBySettings))

        // measuredFar is unaffected by that switch.
        let stillLocks = evaluate(PolicyFixture.lockable(evidence: .measuredFar, settings: settings))
        #expect(stillLocks.lockReason == .userDeparted(.measuredFar))
    }

    @Test func departureThenSilentObeysTheDepartedIdleGuard() {
        let out = evaluate(PolicyFixture.lockable(evidence: .departureThenSilent, inputIdle: .seconds(3)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.userActive))
    }

    @Test func awayWithoutAbsenceEvidenceDoesNotLock() {
        for evidence in [PresenceEvidence.none, .measuredNear] {
            let out = evaluate(PolicyFixture.lockable(evidence: evidence))
            #expect(out.action == nil)
            #expect(out.rationale.contains(.noAbsenceEvidence))
        }
    }

    // MARK: evidenceExpired (silence lock)

    private func silence(
        inputIdle: Duration?,
        now: MonotonicInstant,
        settings: PolicySettings = PolicySettings()
    ) -> PolicySnapshot {
        PolicyFixture.snapshot(presence: .unknown(.evidenceExpired), presenceSince: PolicyFixture.at(0),
                               evidence: .none, inputIdle: inputIdle, settings: settings, now: now)
    }

    /// T-10 — silence is loss of evidence, not absence. Without the second supporting
    /// signal there is nothing to lock on (ADR-008, security.md §2.3).
    @Test func evidenceExpiredWithoutInputIdleIsInsufficient() {
        let out = evaluate(silence(inputIdle: nil, now: PolicyFixture.at(1_000)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.insufficientEvidence))
    }

    @Test func evidenceExpiredWithRecentInputDoesNotLock() {
        let out = evaluate(silence(inputIdle: .seconds(10), now: PolicyFixture.at(1_000)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.userActive))
    }

    @Test func evidenceExpiredWaitsForTheSilenceTimeoutAndPublishesTheDeadline() {
        let out = evaluate(silence(inputIdle: .seconds(300), now: PolicyFixture.at(100)))
        #expect(out.action == nil)
        #expect(out.nextDeadline == PolicyFixture.at(180))
        #expect(out.rationale.contains(.waiting(until: PolicyFixture.at(180))))
    }

    @Test func evidenceExpiredLocksOnceTheSilenceTimeoutElapses() {
        let atDeadline = evaluate(silence(inputIdle: .seconds(300), now: PolicyFixture.at(180)))
        #expect(atDeadline.lockReason == .evidenceExpired)

        let past = evaluate(silence(inputIdle: .seconds(300), now: PolicyFixture.at(400)))
        #expect(past.lockReason == .evidenceExpired)
    }

    @Test func silenceLockNeverDisablesTheRuleEntirely() {
        var settings = PolicySettings()
        settings.silenceLock = .never
        let out = evaluate(silence(inputIdle: .seconds(300), now: PolicyFixture.at(10_000), settings: settings))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.disabledBySettings))
    }

    @Test func silenceIdleGuardIsSeparateFromTheDepartedGuard() {
        var settings = PolicySettings()
        settings.departedIdleGuard = .seconds(15)
        settings.silenceIdleGuard = .seconds(60)
        // 30 s clears the departed guard but not the stricter silence guard.
        let out = evaluate(silence(inputIdle: .seconds(30), now: PolicyFixture.at(400), settings: settings))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.userActive))
    }

    // MARK: presence states that carry no absence evidence

    @Test(arguments: [
        PresenceState.present,
        .departing,
        .unknown(.initial),
        .unknown(.reset(.systemWake)),
        .unknown(.sensorRestored),
    ])
    func nonAbsentPresenceNeverLocks(presence: PresenceState) {
        let out = evaluate(PolicyFixture.snapshot(presence: presence, evidence: .measuredNear))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.noAbsenceEvidence))
    }

    // MARK: settings and preconditions

    /// T-05 — the master switch beats every evidence class.
    @Test(arguments: [PresenceEvidence.measuredFar, .departureThenSilent])
    func autoLockOffNeverLocks(evidence: PresenceEvidence) {
        var settings = PolicySettings()
        settings.autoLock = false
        let out = evaluate(PolicyFixture.lockable(evidence: evidence, settings: settings))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.disabledBySettings))
    }

    @Test func autoLockOffAlsoSuppressesTheSilenceLock() {
        var settings = PolicySettings()
        settings.autoLock = false
        let out = evaluate(silence(inputIdle: .seconds(300), now: PolicyFixture.at(400), settings: settings))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.disabledBySettings))
    }

    /// T-12 — the explicit, accepted cost: a dead sensor means no lock even though the
    /// last known presence is away and the screen is unlocked.
    @Test(arguments: [SensorHealth.degraded(.resetting), .unavailable(.poweredOff), .initializing])
    func sensorNotHealthyNeverLocks(sensor: SensorHealth) {
        let out = evaluate(PolicyFixture.snapshot(presence: .away, evidence: .measuredFar,
                                                  sensor: sensor, screen: .unlocked))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionIndeterminate(.sensor)))
    }

    /// T-17 (policy half) — an unarmed calibration gate blocks Auto Lock.
    @Test func calibrationNotArmedNeverLocks() {
        let out = evaluate(PolicyFixture.snapshot(presence: .away, evidence: .measuredFar,
                                                  calibration: .notArmed(.macMismatch)))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionUnsatisfied(.calibration)))
    }

    /// T-06 — an unknown screen state is never guessed at.
    @Test func screenUnknownNeverLocks() {
        let out = evaluate(PolicyFixture.lockable(screen: .unknown))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionIndeterminate(.screen)))
    }

    @Test func sessionInactiveNeverLocks() {
        let out = evaluate(PolicyFixture.snapshot(presence: .away, evidence: .measuredFar, session: .inactive))
        #expect(out.action == nil)
        #expect(out.rationale.contains(.preconditionUnsatisfied(.session)))
    }

    // MARK: rationale contract

    @Test func rationaleIsNeverEmpty() {
        let snapshots = [
            PolicyFixture.lockable(),
            PolicyFixture.lockable(screen: .unknown),
            PolicyFixture.wakeable(),
            silence(inputIdle: nil, now: PolicyFixture.at(400)),
            PolicyFixture.snapshot(presence: .departing, evidence: .none),
        ]
        for snapshot in snapshots {
            for trigger in [PolicyTrigger.presence, .screen, .deadline, .settings] {
                #expect(!evaluate(snapshot, trigger: trigger).rationale.isEmpty)
            }
        }
    }

    /// The trigger is diagnostic context only — it must never change the decision.
    @Test func triggerDoesNotChangeTheDecision() {
        let snapshot = PolicyFixture.lockable()
        let reasons = [PolicyTrigger.presence, .sensor, .screen, .session, .power, .input,
                       .settings, .calibration, .deadline, .actionOutcome]
            .map { evaluate(snapshot, trigger: $0).lockReason }
        #expect(reasons.allSatisfy { $0 == .userDeparted(.measuredFar) })
    }
}
