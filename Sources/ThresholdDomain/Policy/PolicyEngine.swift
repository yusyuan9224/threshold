// Policy engine (docs/specs/proximity-domain.md §6.2–§6.4).
//
// The decision is a pure function of the `PolicySnapshot` plus the engine's own action
// ledger. No clock is read (ADR-003); every instant arrives on the snapshot.
//
// Shape of one evaluation:
//   1. invalidate ledger entries from superseded episodes
//   2. record confirmation for locks whose screen is now locked
//   3. try the lock branch; if it proposes nothing, try the wake branch
//
// The two branches are mutually exclusive in practice — lock needs an unlocked screen and
// an awake display, wake needs the opposite — so at most one can pass its preconditions.
// When neither acts, both rationales are returned so diagnostics can say why.

public struct PolicyEngine {
    private var entries: [LedgerEntry] = []
    private var nextActionRaw: UInt64 = 1

    public init() {}

    /// Read-only view of the action ledger, in creation order.
    public var ledger: [LedgerEntry] { entries }

    /// The precondition gate is asked about the *kind* of action; the lock reason never
    /// changes the answer, so any reason serves as the probe.
    private static let lockGate = ActionKind.lock(.evidenceExpired)

    // MARK: - Evaluation

    /// - Parameter trigger: diagnostic context only. It is deliberately left unnamed so the
    ///   compiler enforces §6.2's rule that it cannot participate in the decision.
    public mutating func evaluate(_ snapshot: PolicySnapshot, trigger _: PolicyTrigger) -> PolicyOutput {
        var ledgerRationale = invalidateEntries(outside: snapshot.proximity.episode)
        ledgerRationale += confirmLocks(in: snapshot)

        let lock = evaluateLock(snapshot)
        if lock.action != nil {
            return PolicyOutput(action: lock.action, nextDeadline: lock.nextDeadline,
                                rationale: deduplicated(ledgerRationale + lock.rationale))
        }

        let wake = evaluateWake(snapshot)
        if wake.action != nil {
            return PolicyOutput(action: wake.action, nextDeadline: wake.nextDeadline,
                                rationale: deduplicated(ledgerRationale + wake.rationale))
        }

        return PolicyOutput(action: nil,
                            nextDeadline: lock.nextDeadline ?? wake.nextDeadline,
                            rationale: deduplicated(ledgerRationale + lock.rationale + wake.rationale))
    }

    // MARK: - Outcomes

    /// - Parameter at: accepted for symmetry with the rest of the effect pipeline. Retry
    ///   timing is measured from dispatch, not from acknowledgement, so it is not stored.
    public mutating func acknowledge(
        actionID: ActionID,
        episodeID: EpisodeID,
        outcome: ActionOutcome,
        at _: MonotonicInstant
    ) -> AcknowledgeResult {
        guard let index = entries.firstIndex(where: { $0.id == actionID }) else { return .stale }
        // A mismatched episode, or an entry already invalidated by one, is stale: the ledger
        // must not move and nothing may be re-dispatched (security.md §2.6).
        guard entries[index].episode == episodeID, entries[index].stage != .stale else { return .stale }

        switch outcome {
        case .completed:
            entries[index].stage = .acknowledged
            return .applied
        case .failed:
            entries[index].stage = .failed
            return .failed
        }
    }

    /// Called by the Coordinator once a proposed action has been handed to its controller.
    /// From `issued` on, the effect is committed and is never withdrawn (architecture.md §6).
    public mutating func markIssued(_ id: ActionID, at instant: MonotonicInstant) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].stage == .proposed else { return }
        entries[index].stage = .issued
        entries[index].issuedAt = instant
    }

    // MARK: - Ledger bookkeeping

    private mutating func invalidateEntries(outside episode: EpisodeID) -> [PolicyRationale] {
        var rationale: [PolicyRationale] = []
        for index in entries.indices where entries[index].episode != episode && entries[index].isLive {
            entries[index].stage = .stale
            rationale.append(.staleOutcome(entries[index].id))
        }
        return rationale
    }

    /// A locked screen is the only evidence that a lock actually took effect.
    private mutating func confirmLocks(in snapshot: PolicySnapshot) -> [PolicyRationale] {
        guard snapshot.preconditions.screen == .locked else { return [] }
        var rationale: [PolicyRationale] = []
        for index in entries.indices
        where entries[index].episode == snapshot.proximity.episode && entries[index].isLock && entries[index].isLive {
            entries[index].stage = .confirmed
            rationale.append(.confirmed(entries[index].id))
        }
        return rationale
    }

    // MARK: - Lock branch

    private mutating func evaluateLock(_ snapshot: PolicySnapshot) -> Branch {
        guard snapshot.settings.autoLock else { return Branch(rationale: [.disabledBySettings]) }

        switch snapshot.preconditions.check(for: Self.lockGate) {
        case .unsatisfied(let field): return Branch(rationale: [.preconditionUnsatisfied(field)])
        case .indeterminate(let field): return Branch(rationale: [.preconditionIndeterminate(field)])
        case .satisfied: break
        }

        switch lockRule(snapshot) {
        case .decline(let rationale, let deadline):
            return Branch(nextDeadline: deadline, rationale: rationale)
        case .lock(let reason):
            return dispatchLock(reason: reason, snapshot: snapshot)
        }
    }

    /// §6.3 lock rules. Pure — it reads the snapshot only.
    private func lockRule(_ snapshot: PolicySnapshot) -> LockRule {
        let proximity = snapshot.proximity
        let settings = snapshot.settings
        let idle = snapshot.evidence.inputIdle

        switch proximity.presence {
        case .away:
            switch proximity.evidence {
            case .measuredFar:
                // Unknown idle does not block a *measured* departure: locking is the safe
                // direction (security.md §2.7).
                if let idle, idle < settings.departedIdleGuard { return .decline([.userActive]) }
                return .lock(.userDeparted(.measuredFar))

            case .departureThenSilent:
                guard settings.lockOnDepartureThenSilent else { return .decline([.disabledBySettings]) }
                if let idle, idle < settings.departedIdleGuard { return .decline([.userActive]) }
                return .lock(.userDeparted(.departureThenSilent))

            case .none, .measuredNear:
                return .decline([.noAbsenceEvidence])
            }

        case .unknown(.evidenceExpired):
            // Silence is loss of evidence, not absence, so this path needs a second
            // supporting signal and a timeout before it may act (ADR-008).
            guard case .afterTimeout(let timeout) = settings.silenceLock else {
                return .decline([.disabledBySettings])
            }
            guard let idle else { return .decline([.insufficientEvidence]) }
            if idle < settings.silenceIdleGuard { return .decline([.userActive]) }

            let due = proximity.presenceSince + timeout
            if snapshot.now < due { return .decline([.waiting(until: due)], deadline: due) }
            return .lock(.evidenceExpired)

        case .present, .departing, .unknown:
            return .decline([.noAbsenceEvidence])
        }
    }

    /// De-duplication and retry for the at-most-one lock entry of this episode (§6.4).
    private mutating func dispatchLock(reason: LockReason, snapshot: PolicySnapshot) -> Branch {
        let episode = snapshot.proximity.episode

        guard let index = entries.firstIndex(where: { $0.episode == episode && $0.isLock }) else {
            let action = appendAction(kind: .lock(reason), episode: episode, at: snapshot.now)
            return Branch(action: action,
                          nextDeadline: snapshot.now + snapshot.settings.retryAfter,
                          rationale: [.proposed(action.id)])
        }

        let entry = entries[index]
        switch entry.stage {
        case .confirmed:
            return Branch(rationale: [.confirmed(entry.id)])
        case .gaveUp:
            return Branch(rationale: [.gaveUp(entry.id)])
        case .stale:
            return Branch(rationale: [.staleOutcome(entry.id)])
        case .failed:
            // An explicit failure need not wait out `retryAfter`.
            return retryLock(at: index, reason: reason, snapshot: snapshot)
        case .proposed, .issued, .acknowledged:
            let due = entry.issuedAt + snapshot.settings.retryAfter
            guard snapshot.now >= due else {
                return Branch(nextDeadline: due, rationale: [.alreadyIssued(entry.id)])
            }
            return retryLock(at: index, reason: reason, snapshot: snapshot)
        }
    }

    private mutating func retryLock(at index: Int, reason: LockReason, snapshot: PolicySnapshot) -> Branch {
        let id = entries[index].id
        guard entries[index].attempts < snapshot.settings.maxAttempts else {
            entries[index].stage = .gaveUp
            return Branch(rationale: [.gaveUp(id)])
        }

        entries[index].attempts += 1
        entries[index].stage = .proposed
        entries[index].issuedAt = snapshot.now

        let action = PolicyAction(id: id, kind: .lock(reason),
                                  episode: entries[index].episode, proposedAt: snapshot.now)
        return Branch(action: action,
                      nextDeadline: snapshot.now + snapshot.settings.retryAfter,
                      rationale: [.retrying(id, attempt: entries[index].attempts)])
    }

    // MARK: - Wake branch

    private mutating func evaluateWake(_ snapshot: PolicySnapshot) -> Branch {
        guard snapshot.settings.wakeOnReturn else { return Branch(rationale: [.disabledBySettings]) }

        switch snapshot.preconditions.check(for: .wake) {
        case .unsatisfied(let field): return Branch(rationale: [.preconditionUnsatisfied(field)])
        case .indeterminate(let field): return Branch(rationale: [.preconditionIndeterminate(field)])
        case .satisfied: break
        }

        guard snapshot.proximity.presence == .present else { return Branch(rationale: [.presenceUncertain]) }

        // The window keeps wake on the *arrival edge*: someone sitting at a locked Mac must
        // not have the display lit over and over.
        guard snapshot.now - snapshot.proximity.presenceSince <= snapshot.settings.wakeWindow else {
            return Branch(rationale: [.outsideWakeWindow])
        }

        // One wake per arrival episode, never retried: a display that failed to light is a
        // nuisance, not a security hole.
        if let existing = entries.first(where: { $0.episode == snapshot.proximity.episode && $0.kind == .wake }) {
            return Branch(rationale: [.alreadyIssued(existing.id)])
        }

        let action = appendAction(kind: .wake, episode: snapshot.proximity.episode, at: snapshot.now)
        return Branch(action: action, rationale: [.proposed(action.id)])
    }

    // MARK: - Helpers

    private mutating func appendAction(kind: ActionKind, episode: EpisodeID, at now: MonotonicInstant) -> PolicyAction {
        let id = ActionID(nextActionRaw)
        nextActionRaw &+= 1
        entries.append(LedgerEntry(id: id, kind: kind, episode: episode,
                                   stage: .proposed, attempts: 1, issuedAt: now))
        return PolicyAction(id: id, kind: kind, episode: episode, proposedAt: now)
    }

    /// Order-preserving de-duplication: the two branches often reach the same conclusion
    /// about the same field, and repeating it adds nothing.
    private func deduplicated(_ rationale: [PolicyRationale]) -> [PolicyRationale] {
        var unique: [PolicyRationale] = []
        for item in rationale where !unique.contains(item) { unique.append(item) }
        return unique
    }

    /// One branch's contribution to the output.
    private struct Branch {
        var action: PolicyAction?
        var nextDeadline: MonotonicInstant?
        var rationale: [PolicyRationale]

        init(action: PolicyAction? = nil, nextDeadline: MonotonicInstant? = nil, rationale: [PolicyRationale]) {
            self.action = action
            self.nextDeadline = nextDeadline
            self.rationale = rationale
        }
    }

    private enum LockRule {
        case lock(LockReason)
        case decline([PolicyRationale], deadline: MonotonicInstant? = nil)
    }
}
