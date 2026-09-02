import Testing
@testable import ThresholdDomain

/// Seeded linear congruential generator. The Domain and its tests import nothing, so the source of
/// randomness is written out here — and being seeded, any failure is reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(below bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() >> 33) % bound
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(below: range.upperBound - range.lowerBound + 1)
    }
}

/// The only presence transitions §4.3 permits, as `from|to|cause`.
private let legalPresenceTransitions: Set<String> = [
    "unknown|present|confirmedNear",          // #1
    "unknown|away|measuredFar",               // #2
    "present|departing|signalWeakened",       // #3
    "departing|present|signalRecovered",      // #4
    "departing|away|measuredFar",             // #5
    "departing|away|departureThenSilent",     // #6
    "departing|unknown|evidenceExpired",      // #7
    "present|unknown|evidenceExpired",        // #8
    "away|present|confirmedNear",             // #9
    "away|unknown|evidenceExpired",           // #10
    // #11 — from any state, on reset or sensor restore.
    "unknown|unknown|reset", "present|unknown|reset", "departing|unknown|reset", "away|unknown|reset",
    "unknown|unknown|sensorRestored", "present|unknown|sensorRestored",
    "departing|unknown|sensorRestored", "away|unknown|sensorRestored",
]

private func kind(of label: String) -> String {
    label.prefix { $0 != "(" }.description
}

private func causeKey(_ cause: TransitionCause) -> String {
    switch cause {
    case .confirmedNear: return "confirmedNear"
    case .measuredFar: return "measuredFar"
    case .signalWeakened: return "signalWeakened"
    case .signalRecovered: return "signalRecovered"
    case .departureThenSilent: return "departureThenSilent"
    case .evidenceExpired: return "evidenceExpired"
    case .reset: return "reset"
    case .sensorRestored: return "sensorRestored"
    case .sensorBecameHealthy: return "sensorBecameHealthy"
    case .sensorDegraded: return "sensorDegraded"
    case .sensorUnavailable: return "sensorUnavailable"
    case .sensorInitializing: return "sensorInitializing"
    case .deviceSilent: return "deviceSilent"
    case .deviceReceiving: return "deviceReceiving"
    }
}

/// Checks the invariants that must hold after *every* input, whatever the input was.
private struct InvariantChecker {
    var presence = PresenceState.unknown(.initial).label
    var episode: UInt64 = 0
    var violations: [String] = []
    var seen: Set<String> = []
    /// How often each row was walked. Reported when a row is missing, so the next person sees
    /// which paths the generator did reach rather than only which one it did not.
    var counts: [String: Int] = [:]

    var coverageReport: String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
    var presenceTransitions = 0

    mutating func check(_ transitions: [ProximityTransition], snapshot: ProximitySnapshot, step: Int, latestInput: Int64) {
        let presenceOnes = transitions.filter { $0.axis == .presence }
        for transition in presenceOnes {
            presenceTransitions += 1
            let key = "\(kind(of: transition.from))|\(kind(of: transition.to))|\(causeKey(transition.cause))"
            seen.insert(key); counts[key, default: 0] += 1
            if !legalPresenceTransitions.contains(key) {
                violations.append("step \(step): illegal transition \(key)")
            }
            if transition.from != presence {
                violations.append("step \(step): transition starts from \(transition.from) but the engine was in \(presence)")
            }
            presence = transition.to
        }
        if snapshot.presence.label != presence {
            violations.append("step \(step): snapshot says \(snapshot.presence.label), transitions say \(presence)")
        }
        if snapshot.episode.raw != episode + UInt64(presenceOnes.count) {
            violations.append("step \(step): episode \(episode) → \(snapshot.episode.raw) across \(presenceOnes.count) presence transitions")
        }
        episode = snapshot.episode.raw
        if let deadline = snapshot.nextDeadline, deadline.nanoseconds < latestInput {
            violations.append("step \(step): deadline \(deadline.nanoseconds) precedes the last input \(latestInput)")
        }
    }
}

// MARK: - Walk generation

/// One generated input as a time advance plus a shape. The whole walk is built before anything is
/// replayed, so the scripted episodes below read as scripts rather than as branches inside a loop.
private enum GeneratedStep {
    case observation(device: String, rssi: Int)
    case tick
    case sensor(SensorStatus)
    case reset(ResetReason)
}

private struct WalkStep {
    let advanceMs: Int64
    let step: GeneratedStep
}

/// Scripted stretches spliced into the random walk.
///
/// Rows #6 and #7 are unreachable by chance at any plausible rate: both need the walk to be in
/// `departing` — a state it occupies for a few inputs in a hundred thousand — and then to fall
/// completely silent with no reset or sensor event interrupting. Leaving them to luck is how a
/// property test ends up asserting invariants over paths it never walks.
private enum Episode {
    static let near = -45
    static let far = -95

    private static func observations(_ count: Int, _ rssi: Int, everyMs: Int64 = 1_000) -> [WalkStep] {
        (0..<count).map { _ in WalkStep(advanceMs: everyMs, step: .observation(device: "device-A", rssi: rssi)) }
    }

    private static func ticks(_ count: Int, everyMs: Int64) -> [WalkStep] {
        (0..<count).map { _ in WalkStep(advanceMs: everyMs, step: .tick) }
    }

    /// Row #6, `departing → away` on `departureThenSilent`, then row #9 on the way back.
    ///
    /// The far run has to be long enough to cross into departing *and* leave three measured
    /// sub-exit values in the lookback, but must stop before the departure delay expires: one more
    /// measured far sample after that and row #5 fires first. Silence then has to last past the
    /// silent threshold but stop short of the evidence timeout, so #6 lands and #10 does not.
    static var departureThenSilence: [WalkStep] {
        [WalkStep(advanceMs: 0, step: .sensor(.available))]
            + observations(12, near)          // → present
            + observations(7, far)            // departing on the fourth; three more fill the lookback
            + ticks(8, everyMs: 1_500)        // silent at +10 s, #6 at +10.5 s, still short of +30 s
            + observations(12, near)          // → back to present, exercising #9 from a real away
    }

    /// Row #7, `departing → unknown` on `evidenceExpired`.
    ///
    /// The same walk into departing, but silence starts on the very sample that crossed, so the
    /// lookback still holds the strong values from before the weakening and the #6 prelude fails.
    static var suddenSilenceWhileDeparting: [WalkStep] {
        [WalkStep(advanceMs: 0, step: .sensor(.available))]
            + observations(12, near)
            + observations(4, far)            // crosses into departing on the last one
            + ticks(16, everyMs: 2_500)       // past the 30 s evidence timeout
    }

    /// Row #4, `departing → present` on `signalRecovered`: someone stepping away from the desk and
    /// coming straight back. The near run has to outlast the median stage before the EMA recovers.
    static var recoveryWhileDeparting: [WalkStep] {
        [WalkStep(advanceMs: 0, step: .sensor(.available))]
            + observations(12, near)
            + observations(4, far)            // → departing
            + observations(8, near)           // → present again, well inside the departure delay
    }

    /// Row #5, `departing → away` on `measuredFar`: still being heard, still far, and far for
    /// longer than the departure delay. The far run has to outlast that delay with real samples.
    static var departureWhileStillHeard: [WalkStep] {
        [WalkStep(advanceMs: 0, step: .sensor(.available))]
            + observations(12, near)
            + observations(16, far)           // departing on the fourth, #5 eleven samples later
    }

    /// Row #8, `present → unknown` on `evidenceExpired`: T-13's shape — a strong signal that stops
    /// dead. It must never pass through departing on the way, which is what makes it worth walking.
    static var suddenSilenceWhilePresent: [WalkStep] {
        [WalkStep(advanceMs: 0, step: .sensor(.available))]
            + observations(12, near)
            + ticks(16, everyMs: 2_500)
    }

    /// Every script, for uniform selection.
    static let all: [[WalkStep]] = [
        departureThenSilence,
        suddenSilenceWhileDeparting,
        recoveryWhileDeparting,
        departureWhileStillHeard,
        suddenSilenceWhilePresent,
    ]
}

/// Builds the walk: mostly noise, with the two episodes spliced in often enough to be certain and
/// rarely enough that the noise still dominates.
private func makeWalk(seed: UInt64, length: Int) -> [WalkStep] {
    var random = SeededRandom(seed: seed)
    var walk: [WalkStep] = []
    /// While positive the generator emits ticks only. Quiet stretches are what let the silence rows
    /// fire from ordinary noise as well as from the scripts.
    var quietTicksRemaining = 0

    while walk.count < length {
        if quietTicksRemaining > 0 {
            quietTicksRemaining -= 1
            walk.append(WalkStep(advanceMs: Int64(random.int(in: 0...2_000)), step: .tick))
            continue
        }
        if random.int(below: 500) == 0 {
            walk += Episode.all[random.int(below: Episode.all.count)]
            continue
        }
        if random.int(below: 300) == 0 {
            quietTicksRemaining = random.int(in: 20...60)
            continue
        }

        // Time usually advances by up to 2 s; one input in fifty arrives out of order.
        let advance = random.int(below: 50) == 0
            ? Int64(-random.int(in: 0...3_000))
            : Int64(random.int(in: 0...2_000))

        switch random.int(below: 100) {
        case 0..<58:
            let name = random.int(below: 10) == 0 ? "device-Z" : (random.int(below: 2) == 0 ? "device-A" : "device-B")
            // Mostly plausible dBm, occasionally impossible, so the validator is exercised too.
            let rssi = random.int(below: 20) == 0 ? random.int(in: -400...400) : random.int(in: -110...(-30))
            walk.append(WalkStep(advanceMs: advance, step: .observation(device: name, rssi: rssi)))
        case 58..<88:
            walk.append(WalkStep(advanceMs: advance, step: .tick))
        case 88..<97:
            let status: SensorStatus
            switch random.int(below: 4) {
            case 0: status = .degraded(.scanInterrupted)
            case 1: status = .unavailable(.poweredOff)
            case 2: status = .unavailable(.scannerFailed)
            default: status = .available
            }
            walk.append(WalkStep(advanceMs: advance, step: .sensor(status)))
        default:
            let reasons: [ResetReason] = [.systemWake, .bluetoothReset, .sessionChanged, .devicesChanged]
            walk.append(WalkStep(advanceMs: advance, step: .reset(reasons[random.int(below: reasons.count)])))
        }
    }
    return Array(walk.prefix(length))
}

/// Every presence row of §4.3 that is not the reset/sensor-restore row, as `from|to|cause`.
/// Rows #5 and #6 share a from/to pair and differ only in cause, which is the distinction the
/// evidence provenance exists to carry, so both are listed.
private let measuredAndSilenceRows = [
    "unknown|present|confirmedNear",          // #1
    "unknown|away|measuredFar",               // #2
    "present|departing|signalWeakened",       // #3
    "departing|present|signalRecovered",      // #4
    "departing|away|measuredFar",             // #5
    "departing|away|departureThenSilent",     // #6
    "departing|unknown|evidenceExpired",      // #7
    "present|unknown|evidenceExpired",        // #8
    "away|present|confirmedNear",             // #9
    "away|unknown|evidenceExpired",           // #10
]

@Suite("ProximityEngine — property tests")
struct ProximityEnginePropertyTests {
    /// T-15: 100,000 inputs — including malformed, unknown-device and out-of-order ones — may not
    /// produce a transition outside the table, a non-monotonic episode, or a past deadline.
    @Test func t15_randomInputSequencesStayInsideTheTransitionTable() {
        var engine = ProximityEngine(
            fusion: AnyDeviceFusion(),
            devices: [DeviceID("device-A"), DeviceID("device-B")],
            gate: .armed(testProfile)
        )
        var checker = InvariantChecker()
        var nanoseconds: Int64 = 0
        var latestInput: Int64 = 0

        for (step, walkStep) in makeWalk(seed: 0x5E_ED_15, length: 100_000).enumerated() {
            nanoseconds += walkStep.advanceMs * 1_000_000
            let at = MonotonicInstant(nanoseconds: nanoseconds)
            latestInput = max(latestInput, nanoseconds)

            let input: EngineInput
            switch walkStep.step {
            case .observation(let device, let rssi):
                input = .observation(BLEObservation(device: DeviceID(device), at: at, rssi: rssi))
            case .tick:
                input = .tick(at: at)
            case .sensor(let status):
                input = .sensor(status, at: at)
            case .reset(let reason):
                input = .reset(reason, at: at)
            }

            let transitions = engine.handle(input)
            checker.check(transitions, snapshot: engine.snapshot, step: step, latestInput: latestInput)
        }

        #expect(checker.violations.isEmpty, "\(checker.violations.prefix(5))")
        #expect(checker.presenceTransitions > 100, "the generator must actually exercise the state machine")
        // Every row of the table that is not a reset must actually be walked. Without this the
        // invariant checks above would pass just as happily over paths the walk never reaches.
        for expected in measuredAndSilenceRows {
            #expect(checker.seen.contains(expected), "never exercised \(expected); walked \(checker.coverageReport)")
        }
    }

    @Test func randomSequencesNeverProduceAScoreOutsideTheUnitInterval() {
        var random = SeededRandom(seed: 99)
        var engine = ProximityEngine(devices: [DeviceID("device-A")], gate: .armed(testProfile))
        var nanoseconds: Int64 = 0
        for _ in 0..<20_000 {
            nanoseconds += Int64(random.int(in: 0...5_000)) * 1_000_000
            let at = MonotonicInstant(nanoseconds: nanoseconds)
            _ = engine.handle(.observation(BLEObservation(device: DeviceID("device-A"), at: at, rssi: random.int(in: -120...0))))
            _ = engine.handle(.tick(at: at))
            if let fused = engine.snapshot.fusedScore {
                #expect(!fused.isNaN)
                #expect(fused >= 0 && fused <= 1)
            }
            for track in engine.snapshot.devices.values {
                if let score = track.score {
                    #expect(score.value >= 0 && score.value <= 1)
                }
            }
        }
    }
}
