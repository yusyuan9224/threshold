import Testing
@testable import ThresholdDomain

/// Property-style coverage of the single invariant the whole product leans on:
/// **no action ever escapes an unsatisfied precondition** (security.md §2.1).
@Suite("Policy engine — invariants")
struct PolicyEnginePropertyTests {
    /// Deterministic PRNG so a failure is reproducible from the seed alone.
    /// SplitMix64 — small, well-distributed, and stdlib-only.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let presences: [PresenceState] = [
        .unknown(.initial), .unknown(.evidenceExpired), .unknown(.reset(.systemWake)),
        .unknown(.sensorRestored), .present, .departing, .away,
    ]
    private static let evidences: [PresenceEvidence] = [.none, .measuredNear, .measuredFar, .departureThenSilent]
    private static let sensors: [SensorHealth] = [
        .healthy, .initializing, .degraded(.resetting), .degraded(.scanInterrupted),
        .unavailable(.poweredOff), .unavailable(.unauthorized), .unavailable(.unsupported),
        .unavailable(.scannerFailed),
    ]
    private static let sessions: [SessionState] = [.active, .inactive, .unknown]
    private static let powers: [PowerState] = [.awake, .displayAsleep, .systemAsleep, .unknown]
    private static let screens: [ScreenState] = [.unlocked, .locked, .unknown]
    private static let gates: [CalibrationGate] = [
        .armed(PolicyFixture.profile), .notArmed(.noProfile), .notArmed(.macMismatch),
        .notArmed(.driftExceeded), .notArmed(.invalid(.overlap)),
    ]
    private static let idles: [Duration?] = [nil, .seconds(0), .seconds(5), .seconds(30), .seconds(90), .seconds(600)]
    private static let triggers: [PolicyTrigger] = [
        .presence, .sensor, .screen, .session, .power, .input, .settings, .calibration, .deadline, .actionOutcome,
    ]

    private func randomSnapshot(using rng: inout SplitMix64) -> PolicySnapshot {
        var settings = PolicySettings()
        settings.autoLock = Bool.random(using: &rng)
        settings.wakeOnReturn = Bool.random(using: &rng)
        settings.lockOnDepartureThenSilent = Bool.random(using: &rng)
        settings.silenceLock = Bool.random(using: &rng) ? .never : .afterTimeout(.seconds(Int.random(in: 1...300, using: &rng)))

        let sensor = Self.sensors.randomElement(using: &rng)!
        let presenceSince = PolicyFixture.at(Double(Int.random(in: 0...500, using: &rng)))
        let now = PolicyFixture.at(Double(Int.random(in: 0...1_000, using: &rng)))

        return PolicyFixture.snapshot(
            presence: Self.presences.randomElement(using: &rng)!,
            presenceSince: presenceSince,
            episode: EpisodeID(UInt64(Int.random(in: 1...4, using: &rng))),
            evidence: Self.evidences.randomElement(using: &rng)!,
            sensor: sensor,
            session: Self.sessions.randomElement(using: &rng)!,
            power: Self.powers.randomElement(using: &rng)!,
            screen: Self.screens.randomElement(using: &rng)!,
            calibration: Self.gates.randomElement(using: &rng)!,
            inputIdle: Self.idles.randomElement(using: &rng)!,
            settings: settings,
            now: now
        )
    }

    /// Whatever else the engine decides, an emitted action's own preconditions must hold,
    /// and a snapshot satisfying neither gate must yield no action at all.
    @Test func noActionEverEscapesAnUnsatisfiedPrecondition() {
        var rng = SplitMix64(state: 0x7A15_C0DE_0000_0001)
        for _ in 0..<5_000 {
            let snapshot = randomSnapshot(using: &rng)
            let trigger = Self.triggers.randomElement(using: &rng)!

            var engine = PolicyEngine()
            let out = engine.evaluate(snapshot, trigger: trigger)

            if let action = out.action {
                #expect(snapshot.preconditions.check(for: action.kind) == .satisfied)
                #expect(action.episode == snapshot.proximity.episode)
                #expect(action.proposedAt == snapshot.now)
            } else {
                #expect(!out.rationale.isEmpty)
            }

            let lockOK = snapshot.preconditions.check(for: .lock(.evidenceExpired)) == .satisfied
            let wakeOK = snapshot.preconditions.check(for: .wake) == .satisfied
            if !lockOK && !wakeOK {
                #expect(out.action == nil)
            }
        }
    }

    /// The same invariant holds for a long-lived engine whose ledger accumulates state.
    @Test func theInvariantSurvivesALongLivedLedger() {
        var rng = SplitMix64(state: 0x5EED_1234_5678_9ABC)
        var engine = PolicyEngine()

        for _ in 0..<5_000 {
            let snapshot = randomSnapshot(using: &rng)
            let out = engine.evaluate(snapshot, trigger: Self.triggers.randomElement(using: &rng)!)

            #expect(!out.rationale.isEmpty)
            if let action = out.action {
                #expect(snapshot.preconditions.check(for: action.kind) == .satisfied)
                engine.markIssued(action.id, at: snapshot.now)
            }
            // At most one entry per (episode, kind) — the ledger must not grow without bound.
            let keys = engine.ledger.map { entry -> String in
                let kind: String
                switch entry.kind {
                case .lock: kind = "lock"
                case .wake: kind = "wake"
                }
                return "\(entry.episode.raw)-\(kind)"
            }
            #expect(Set(keys).count == keys.count)
        }
    }

    /// Evaluation must be a pure function of the snapshot plus the ledger: the same
    /// snapshot on two identical engines yields the same decision.
    @Test func evaluationIsDeterministic() {
        var rng = SplitMix64(state: 0x0DDB_A11C_0FFE_E123)
        for _ in 0..<1_000 {
            let snapshot = randomSnapshot(using: &rng)
            var a = PolicyEngine()
            var b = PolicyEngine()
            let first = a.evaluate(snapshot, trigger: .presence)
            let second = b.evaluate(snapshot, trigger: .presence)

            #expect(first.action?.kind == second.action?.kind)
            #expect(first.action?.episode == second.action?.episode)
            #expect(first.nextDeadline == second.nextDeadline)
            #expect(first.rationale == second.rationale)
        }
    }
}
