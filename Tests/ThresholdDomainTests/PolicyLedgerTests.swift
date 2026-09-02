import Testing
@testable import ThresholdDomain

/// Action ledger: de-duplication, retry and stale protection
/// (proximity-domain.md §6.4, architecture.md §6).
@Suite("Policy engine — action ledger")
struct PolicyLedgerTests {
    private func lockable(episode: EpisodeID = EpisodeID(1),
                          screen: ScreenState = .unlocked,
                          at seconds: Double) -> PolicySnapshot {
        PolicyFixture.lockable(episode: episode, screen: screen, now: PolicyFixture.at(seconds))
    }

    // MARK: de-duplication

    /// T-09 — the screen state lags the lock by some milliseconds; five re-evaluations in
    /// that gap must still dispatch exactly one lock.
    @Test func fiveEvaluationsBeforeRetryAfterDispatchExactlyOneLock() {
        var engine = PolicyEngine()
        var dispatched: [PolicyAction] = []

        for step in 0..<5 {
            let now = 100.0 + Double(step)
            let out = engine.evaluate(lockable(at: now), trigger: .screen)
            if let action = out.action {
                dispatched.append(action)
                engine.markIssued(action.id, at: PolicyFixture.at(now))
            } else {
                #expect(out.rationale.contains(.alreadyIssued(dispatched[0].id)))
            }
        }

        #expect(dispatched.count == 1)
        #expect(engine.ledger.count == 1)
        #expect(engine.ledger[0].attempts == 1)
        #expect(engine.ledger[0].stage == .issued)
    }

    /// T-09 — once retryAfter has elapsed and the screen is still unlocked, the lock is
    /// re-dispatched up to maxAttempts, then abandoned.
    @Test func lockRetriesUpToMaxAttemptsThenGivesUp() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let secondAttempt = engine.evaluate(lockable(at: 105), trigger: .deadline)
        #expect(secondAttempt.action?.id == id)
        #expect(secondAttempt.rationale.contains(.retrying(id, attempt: 2)))
        engine.markIssued(id, at: PolicyFixture.at(105))

        let thirdAttempt = engine.evaluate(lockable(at: 110), trigger: .deadline)
        #expect(thirdAttempt.action?.id == id)
        #expect(thirdAttempt.rationale.contains(.retrying(id, attempt: 3)))
        engine.markIssued(id, at: PolicyFixture.at(110))

        let gaveUp = engine.evaluate(lockable(at: 115), trigger: .deadline)
        #expect(gaveUp.action == nil)
        #expect(gaveUp.rationale.contains(.gaveUp(id)))
        #expect(engine.ledger[0].stage == .gaveUp)
        #expect(engine.ledger[0].attempts == 3)

        // Abandoned stays abandoned for this episode.
        let later = engine.evaluate(lockable(at: 200), trigger: .deadline)
        #expect(later.action == nil)
        #expect(later.rationale.contains(.gaveUp(id)))
    }

    @Test func aPendingRetryIsPublishedAsTheNextDeadline() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let waiting = engine.evaluate(lockable(at: 102), trigger: .screen)
        #expect(waiting.action == nil)
        #expect(waiting.nextDeadline == PolicyFixture.at(105))
    }

    // MARK: confirmation

    @Test func observingALockedScreenConfirmsTheIssuedLock() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let confirmed = engine.evaluate(lockable(screen: .locked, at: 101), trigger: .screen)
        #expect(confirmed.action == nil)
        #expect(confirmed.rationale.contains(.confirmed(id)))
        #expect(engine.ledger[0].stage == .confirmed)

        // A confirmed lock is never re-dispatched, even long after retryAfter.
        let later = engine.evaluate(lockable(at: 200), trigger: .deadline)
        #expect(later.action == nil)
        #expect(later.rationale.contains(.confirmed(id)))
    }

    // MARK: stale protection

    /// T-07 — an outcome that names a different episode is ignored entirely: it neither
    /// mutates the ledger nor causes a re-dispatch (security.md §2.6).
    @Test func acknowledgeWithAMismatchedEpisodeIsStaleAndLeavesTheLedgerUntouched() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(episode: EpisodeID(1), at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let before = engine.ledger
        let result = engine.acknowledge(actionID: id, episodeID: EpisodeID(2),
                                        outcome: .completed, at: PolicyFixture.at(101))
        #expect(result == .stale)
        #expect(engine.ledger == before)
    }

    @Test func acknowledgeOfAnUnknownActionIsStale() {
        var engine = PolicyEngine()
        let result = engine.acknowledge(actionID: ActionID(9_999), episodeID: EpisodeID(1),
                                        outcome: .completed, at: PolicyFixture.at(100))
        #expect(result == .stale)
        #expect(engine.ledger.isEmpty)
    }

    /// T-07 — presence recovered, so a new episode began; it gets its own lock and the
    /// previous episode's entry is invalidated.
    @Test func aNewEpisodeGetsItsOwnLockAndInvalidatesTheOldEntry() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(episode: EpisodeID(1), at: 100), trigger: .presence)
        let firstID = try #require(first.action?.id)
        engine.markIssued(firstID, at: PolicyFixture.at(100))

        let second = engine.evaluate(lockable(episode: EpisodeID(2), at: 102), trigger: .presence)
        let secondID = try #require(second.action?.id)
        #expect(secondID != firstID)
        #expect(second.action?.episode == EpisodeID(2))
        #expect(engine.ledger.first { $0.id == firstID }?.stage == .stale)
        #expect(engine.ledger.first { $0.id == secondID }?.stage == .proposed)
    }

    /// A late outcome for an entry already invalidated by a new episode is still stale.
    @Test func acknowledgeOfAnInvalidatedEntryIsStale() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(episode: EpisodeID(1), at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))
        _ = engine.evaluate(lockable(episode: EpisodeID(2), at: 102), trigger: .presence)

        let before = engine.ledger
        let result = engine.acknowledge(actionID: id, episodeID: EpisodeID(1),
                                        outcome: .completed, at: PolicyFixture.at(103))
        #expect(result == .stale)
        #expect(engine.ledger == before)
    }

    // MARK: outcomes

    @Test func completedOutcomeIsRecordedAsAcknowledged() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let result = engine.acknowledge(actionID: id, episodeID: EpisodeID(1),
                                        outcome: .completed, at: PolicyFixture.at(101))
        #expect(result == .applied)
        #expect(engine.ledger[0].stage == .acknowledged)
    }

    @Test func failedOutcomeAllowsAnImmediateRetryWithinTheAttemptBudget() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        engine.markIssued(id, at: PolicyFixture.at(100))

        let result = engine.acknowledge(actionID: id, episodeID: EpisodeID(1),
                                        outcome: .failed("lock refused"), at: PolicyFixture.at(101))
        #expect(result == .failed)
        #expect(engine.ledger[0].stage == .failed)

        // Immediately — an explicit failure need not wait out retryAfter.
        let retry = engine.evaluate(lockable(at: 101), trigger: .actionOutcome)
        #expect(retry.action?.id == id)
        #expect(retry.rationale.contains(.retrying(id, attempt: 2)))
        #expect(engine.ledger[0].attempts == 2)
    }

    @Test func repeatedFailuresGiveUpAtMaxAttempts() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)

        var now = 100.0
        for _ in 0..<2 {
            engine.markIssued(id, at: PolicyFixture.at(now))
            #expect(engine.acknowledge(actionID: id, episodeID: EpisodeID(1),
                                       outcome: .failed("nope"), at: PolicyFixture.at(now)) == .failed)
            now += 1
            #expect(engine.evaluate(lockable(at: now), trigger: .actionOutcome).action?.id == id)
        }

        engine.markIssued(id, at: PolicyFixture.at(now))
        #expect(engine.acknowledge(actionID: id, episodeID: EpisodeID(1),
                                   outcome: .failed("nope"), at: PolicyFixture.at(now)) == .failed)
        now += 1
        let gaveUp = engine.evaluate(lockable(at: now), trigger: .actionOutcome)
        #expect(gaveUp.action == nil)
        #expect(gaveUp.rationale.contains(.gaveUp(id)))
        #expect(engine.ledger[0].attempts == 3)
    }

    // MARK: lifecycle mechanics

    @Test func markIssuedMovesAProposedActionToIssuedAndStampsTheInstant() throws {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(at: 100), trigger: .presence)
        let id = try #require(first.action?.id)
        #expect(engine.ledger[0].stage == .proposed)

        engine.markIssued(id, at: PolicyFixture.at(103))
        #expect(engine.ledger[0].stage == .issued)
        #expect(engine.ledger[0].issuedAt == PolicyFixture.at(103))

        // Only `proposed` may be issued, so a repeat call changes nothing.
        engine.markIssued(id, at: PolicyFixture.at(104))
        #expect(engine.ledger[0].issuedAt == PolicyFixture.at(103))

        // An unknown id is ignored rather than fabricating an entry.
        engine.markIssued(ActionID(9_999), at: PolicyFixture.at(105))
        #expect(engine.ledger.count == 1)
    }

    @Test func actionIDsIncreaseMonotonically() {
        var engine = PolicyEngine()
        let first = engine.evaluate(lockable(episode: EpisodeID(1), at: 100), trigger: .presence)
        let second = engine.evaluate(lockable(episode: EpisodeID(2), at: 200), trigger: .presence)
        let third = engine.evaluate(lockable(episode: EpisodeID(3), at: 300), trigger: .presence)

        let raws = [first, second, third].compactMap { $0.action?.id.raw }
        #expect(raws.count == 3)
        #expect(raws == raws.sorted())
        #expect(Set(raws).count == 3)
    }

    @Test func theLedgerHoldsAtMostOneLockEntryPerEpisode() {
        var engine = PolicyEngine()
        #expect(engine.ledger.isEmpty)
        _ = engine.evaluate(lockable(episode: EpisodeID(1), at: 100), trigger: .presence)
        #expect(engine.ledger.count == 1)
        _ = engine.evaluate(lockable(episode: EpisodeID(1), at: 101), trigger: .screen)
        #expect(engine.ledger.count == 1)
        _ = engine.evaluate(lockable(episode: EpisodeID(2), at: 102), trigger: .presence)
        #expect(engine.ledger.count == 2)
    }
}
