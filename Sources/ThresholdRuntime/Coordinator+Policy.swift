import ThresholdDomain
import ThresholdSystem

/// Policy evaluation, effect dispatch and deadline scheduling (architecture.md §5.1, §6).
extension Coordinator {

    /// Builds a `PolicySnapshot` from the settled engine snapshot plus the cached system state,
    /// evaluates it, and dispatches whatever it proposes.
    ///
    /// `inputIdle` is polled here rather than cached: no system signal announces the *start* of
    /// idleness, so the only correct value is the one read at decision time. `power` is refreshed
    /// the same way and for the same reason, discovered the hard way: a real departure/return on
    /// 2026-09-03 measured `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`
    /// firing 0 times across 14 real display-sleep/wake cycles on this Mac (macOS 26.6.2), so the
    /// `.power` case in `handle(_:)` never ran and `power` stayed `.awake` through a real lock —
    /// permanently failing the wake precondition even after presence correctly returned to
    /// `.present`. `MacOSPowerStateProvider.current` already falls back to a live `CGDisplayIsAsleep`
    /// query for everything but `.systemAsleep` (which it cannot observe once read, so the cached
    /// value stands); polling it here instead of trusting the notification-fed cache costs nothing
    /// on every other trigger and fixes this one.
    func evaluate(trigger: PolicyTrigger) {
        guard !isStopped else { return }
        let now = clock.now()
        let proximity = engine.snapshot
        power = powerProvider.current

        let snapshot = PolicySnapshot(
            proximity: proximity,
            preconditions: RequiredPreconditions(
                // The engine's sensor axis is the single source of truth; a second copy could
                // disagree with the one folded into `proximity`.
                sensor: proximity.sensor,
                session: session,
                power: power,
                screen: screen,
                calibration: gate
            ),
            evidence: SupportingEvidence(inputIdle: inputProvider.current),
            settings: settings,
            now: now
        )

        let output = policy.evaluate(snapshot, trigger: trigger)
        lastPolicyDeadline = output.nextDeadline
        emit(.policyEvaluated(PolicyEvaluation(
            trigger: trigger,
            at: now,
            action: output.action,
            nextDeadline: output.nextDeadline,
            rationale: output.rationale
        )))

        if let action = output.action {
            // `issued` before the controller is called: from here the effect is committed and is
            // never withdrawn, even if presence recovers (architecture.md §6).
            policy.markIssued(action.id, at: now)
            dispatchEpoch[action.id] = epoch
            emit(.actionDispatched(action))
            dispatch(action)
        }

        rescheduleDeadline(policyDeadline: output.nextDeadline)
    }

    /// Hands the action to its controller on a detached task.
    ///
    /// Detached, and never awaited from inside the actor: a lock controller waits for the screen to
    /// actually lock, and an actor suspended on that would let no other input through in the
    /// meantime. The result comes back as an ordinary `.actionOutcome` input (ADR-006).
    private func dispatch(_ action: PolicyAction) {
        let lockController = self.lockController
        let wakeController = self.wakeController
        Task.detached { [weak self] in
            var outcome = ActionOutcome.completed
            do {
                switch action.kind {
                case .lock(let reason): try await lockController.lock(reason: reason)
                case .wake: try await wakeController.wakeDisplay()
                }
            } catch {
                outcome = .failed(String(describing: error))
            }
            await self?.handle(.actionOutcome(action.id, action.episode, outcome))
        }
    }

    /// Feeds one outcome back into the ledger.
    ///
    /// An outcome from a previous subsystem generation is rejected here, before the ledger sees it:
    /// after a rebuild the action and episode counters restart, so identity alone is no longer
    /// enough to tell an old outcome from a new one.
    func acknowledge(_ id: ActionID, episode: EpisodeID, outcome: ActionOutcome) {
        guard dispatchEpoch[id] == epoch else {
            emit(.actionAcknowledged(id, episode, .stale))
            return
        }

        let result = policy.acknowledge(actionID: id, episodeID: episode, outcome: outcome, at: clock.now())
        emit(.actionAcknowledged(id, episode, result))
        // A stale outcome records and stops: it must not move the ledger and must not cause a
        // re-dispatch (security.md §2.6).
        guard result != .stale else { return }
        evaluate(trigger: .actionOutcome)
    }

    // MARK: - Deadline

    /// Arms a single timer at `min(engine.nextDeadline, policy.nextDeadline)`.
    ///
    /// One task, replaced rather than accumulated: every input path ends here, so an outdated
    /// deadline is always cancelled before a new one is armed.
    func rescheduleDeadline(policyDeadline: MonotonicInstant?) {
        deadlineTask?.cancel()
        deadlineTask = nil
        deadlineEpoch &+= 1
        guard !isStopped else { return }

        let candidates = [engine.snapshot.nextDeadline, policyDeadline].compactMap { $0 }
        guard let next = candidates.min() else { return }

        let epoch = deadlineEpoch
        let clock = self.clock
        deadlineTask = Task.detached { [weak self] in
            do {
                try await clock.sleep(until: next)
            } catch {
                return  // cancelled: a newer deadline has already been armed
            }
            // The clock's own reading, not `next`: a real clock overshoots its deadline, and the
            // engine treats a tick from the past as carrying no information. Whether this delivery
            // is still current is decided inside `deliverDeadlineTick`, not here (see its doc).
            await self?.deliverDeadlineTick(epoch: epoch, at: clock.now())
        }
    }

    /// Delivers the tick armed by `rescheduleDeadline`, but only if nothing has superseded it since
    /// the sleep began.
    ///
    /// The check this replaced — `guard !Task.isCancelled` — ran on the detached task, *outside*
    /// actor isolation, with a window between that check and the hop into the actor where
    /// `.systemWillSleep` could land: cancel the task just after the check passed, and the tick
    /// would still arrive and re-arm a timer while asleep (§5.4). Comparing `epoch` here instead
    /// runs entirely inside actor isolation, so it is serialized against every other mutation
    /// rather than racing it: either this call reaches the actor before `.systemWillSleep` (a
    /// legitimate tick, and whatever it reschedules is promptly cancelled when `.systemWillSleep`
    /// runs next) or after (this guard rejects it outright, since `.systemWillSleep` already bumped
    /// the epoch and set `power`). Both orderings converge on the same safe state: nothing left
    /// scheduled once `.systemWillSleep` has finished.
    func deliverDeadlineTick(epoch: UInt64, at instant: MonotonicInstant) {
        guard !isStopped, epoch == deadlineEpoch, power != .systemAsleep else { return }
        handle(.tick(instant))
    }
}
