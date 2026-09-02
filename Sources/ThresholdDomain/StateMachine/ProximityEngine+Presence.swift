/// One row of the §4.3 transition table, resolved.
struct PresenceStep {
    let to: PresenceState
    let cause: TransitionCause
    let evidence: PresenceEvidence
}

extension ProximityEngine {
    /// Presence advances only while the sensor is trustworthy. While it is not, presence keeps its
    /// last known value so the UI can say "last known", and Policy refuses to act on it (ADR-008).
    mutating func evaluatePresence(measured: Bool) -> [ProximityTransition] {
        let fused = fusion.fuse(orderedTracks)
        fusedScore = fused

        var emitted: [ProximityTransition] = []
        if sensor == .healthy {
            updateCandidates(fused: fused, measured: measured)
            // A single input can legitimately cross more than one row — a long gap can expire the
            // evidence that a departure had just been recorded from. The bound stops any rule
            // combination from cycling.
            var steps = 0
            while steps < 4, let step = nextPresenceStep(fused: fused, measured: measured) {
                steps += 1
                emitted.append(apply(step))
            }
        }
        updateUncertainty()
        return emitted
    }

    /// Threshold run-lengths. The enter candidate tracks the *current* fused score, so recency decay
    /// can only ever delay a confirmation; the exit candidate and the lookback history are fed only
    /// by measured evaluations, so decay can never manufacture far evidence.
    private mutating func updateCandidates(fused: Double?, measured: Bool) {
        guard let fused else {
            enterSince = nil
            exitSince = nil
            return
        }
        if fused >= configuration.enterThreshold {
            if enterSince == nil { enterSince = now }
        } else {
            enterSince = nil
        }

        guard measured else { return }
        measuredHistory.append(fused)
        let lookback = configuration.departureSilentLookback
        if lookback > 0, measuredHistory.count > lookback {
            measuredHistory.removeFirst(measuredHistory.count - lookback)
        }
        if fused < configuration.exitThreshold {
            if exitSince == nil { exitSince = now }
        } else {
            exitSince = nil
        }
    }

    private func nextPresenceStep(fused: Double?, measured: Bool) -> PresenceStep? {
        let enter = configuration.enterThreshold
        let exit = configuration.exitThreshold

        switch presence {
        case .unknown:
            // #1 / #2 — leaving unknown always costs minSamples *and* confirmDuration.
            guard measured, let fused, hasEnoughSamples else { return nil }
            if fused >= enter, sustained(enterSince) {
                return PresenceStep(to: .present, cause: .confirmedNear, evidence: .measuredNear)
            }
            if fused < exit, sustained(exitSince) {
                return PresenceStep(to: .away, cause: .measuredFar, evidence: .measuredFar)
            }
            return nil

        case .present:
            // #3 — weakening is measured, so the evidence provenance does not change yet.
            if measured, let fused, fused < exit {
                return PresenceStep(to: .departing, cause: .signalWeakened, evidence: evidence)
            }
            // #8
            if allDevicesSilent, silenceElapsed(configuration.evidenceTimeout) {
                return PresenceStep(to: .unknown(.evidenceExpired), cause: .evidenceExpired, evidence: .none)
            }
            return nil

        case .departing:
            // #4 — recovery wins over every departure rule.
            if measured, let fused, fused >= enter {
                return PresenceStep(to: .present, cause: .signalRecovered, evidence: .measuredNear)
            }
            // #5 — still hearing it, still far, and it has been far long enough.
            if measured, let fused, fused < exit, dwellElapsed(configuration.departureDelay) {
                return PresenceStep(to: .away, cause: .measuredFar, evidence: .measuredFar)
            }
            // #6 — weakened, then gone. Stronger absence evidence than sudden silence, and labelled
            // separately so Policy can treat it separately. Still not proof of departure.
            if allDevicesSilent, dwellElapsed(configuration.departureDelay), hasWeakPrelude {
                return PresenceStep(to: .away, cause: .departureThenSilent, evidence: .departureThenSilent)
            }
            // #7
            if allDevicesSilent, silenceElapsed(configuration.evidenceTimeout), !hasWeakPrelude {
                return PresenceStep(to: .unknown(.evidenceExpired), cause: .evidenceExpired, evidence: .none)
            }
            return nil

        case .away:
            // #9
            if measured, let fused, hasEnoughSamples, fused >= enter, sustained(enterSince) {
                return PresenceStep(to: .present, cause: .confirmedNear, evidence: .measuredNear)
            }
            // #10
            if allDevicesSilent, silenceElapsed(configuration.evidenceTimeout) {
                return PresenceStep(to: .unknown(.evidenceExpired), cause: .evidenceExpired, evidence: .none)
            }
            return nil
        }
    }

    /// Row #11, shared by `reset(_:)` and by the sensor returning to healthy. Clears every trace of
    /// the previous episode's evidence: whatever was measured before is no longer trustworthy, and
    /// re-earning `present` costs the full `minSamples + confirmDuration` again (§5).
    mutating func resetPresenceAxis(to state: PresenceState, cause: TransitionCause) -> [ProximityTransition] {
        for device in deviceIDs {
            pipelines[device]?.reset()
            lastAccepted[device] = nil
            anchors[device] = now
        }
        measuredHistory.removeAll()
        return [apply(PresenceStep(to: state, cause: cause, evidence: .none))]
    }

    mutating func apply(_ step: PresenceStep) -> ProximityTransition {
        let transition = ProximityTransition(
            axis: .presence,
            from: presence.label,
            to: step.to.label,
            at: now,
            cause: step.cause
        )
        presence = step.to
        presenceSince = now
        episode = episode.next()
        evidence = step.evidence
        lastTransition = step.cause
        enterSince = nil
        exitSince = nil
        presenceUncertain = false
        return transition
    }

    private mutating func updateUncertainty() {
        guard started, case .unknown = presence else {
            presenceUncertain = false
            return
        }
        presenceUncertain = (now - presenceSince) >= configuration.unknownGrace && !hasEnoughSamples
    }

    // MARK: - Predicates

    var allDevicesSilent: Bool {
        !deviceIDs.contains { observationStates[$0] == .receiving }
    }

    /// Best sample count among devices we are currently hearing. A silent device's stale count
    /// must not stand in for evidence.
    var hasEnoughSamples: Bool {
        for device in deviceIDs where observationStates[device] == .receiving {
            if let count = pipelines[device]?.estimate?.sampleCount, count >= configuration.minSamples {
                return true
            }
        }
        return false
    }

    /// Longest silence across all devices, measured from the newest sample any of them produced.
    var silenceAnchor: MonotonicInstant {
        deviceIDs.compactMap { anchors[$0] }.max() ?? now
    }

    func silenceElapsed(_ duration: Duration) -> Bool {
        (now - silenceAnchor) >= duration
    }

    func dwellElapsed(_ duration: Duration) -> Bool {
        (now - presenceSince) >= duration
    }

    func sustained(_ since: MonotonicInstant?) -> Bool {
        guard let since else { return false }
        return (now - since) >= configuration.confirmDuration
    }

    /// Row #6's prelude: the last k measured fused values, all below exit. Fewer than k measurements
    /// on record is not a prelude — it is missing information, which is the whole point of the row.
    var hasWeakPrelude: Bool {
        let lookback = configuration.departureSilentLookback
        guard lookback > 0, measuredHistory.count >= lookback else { return false }
        return measuredHistory.suffix(lookback).allSatisfy { $0 < configuration.exitThreshold }
    }

    // MARK: - Deadline (§4.5)

    /// The earliest instant at which some pending rule could change the answer. Only strictly
    /// future instants qualify: a deadline equal to now has already been evaluated at now.
    mutating func updateDeadline() {
        guard started else {
            deadline = nil
            return
        }
        var candidates: [MonotonicInstant] = []
        for device in deviceIDs where observationStates[device] == .receiving {
            candidates.append((anchors[device] ?? now) + configuration.silentThreshold)
        }
        switch presence {
        case .present, .away:
            candidates.append(silenceAnchor + configuration.evidenceTimeout)
        case .departing:
            candidates.append(silenceAnchor + configuration.evidenceTimeout)
            candidates.append(presenceSince + configuration.departureDelay)
        case .unknown:
            candidates.append(presenceSince + configuration.unknownGrace)
        }
        if let enterSince { candidates.append(enterSince + configuration.confirmDuration) }
        if let exitSince { candidates.append(exitSince + configuration.confirmDuration) }
        deadline = candidates.filter { $0 > now }.min()
    }
}
