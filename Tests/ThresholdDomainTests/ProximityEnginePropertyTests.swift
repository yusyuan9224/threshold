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
    var presenceTransitions = 0

    mutating func check(_ transitions: [ProximityTransition], snapshot: ProximitySnapshot, step: Int, latestInput: Int64) {
        let presenceOnes = transitions.filter { $0.axis == .presence }
        for transition in presenceOnes {
            presenceTransitions += 1
            let key = "\(kind(of: transition.from))|\(kind(of: transition.to))|\(causeKey(transition.cause))"
            seen.insert(key)
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

@Suite("ProximityEngine — property tests")
struct ProximityEnginePropertyTests {
    /// T-15: 100,000 random inputs — including malformed, unknown-device and out-of-order ones —
    /// may not produce a transition outside the table, a non-monotonic episode, or a past deadline.
    @Test func t15_randomInputSequencesStayInsideTheTransitionTable() {
        var random = SeededRandom(seed: 0x5E_ED_15)
        var engine = ProximityEngine(
            fusion: AnyDeviceFusion(),
            devices: [DeviceID("device-A"), DeviceID("device-B")],
            gate: .armed(testProfile)
        )
        var checker = InvariantChecker()
        var nanoseconds: Int64 = 0
        var latestInput: Int64 = 0
        /// While positive the generator emits ticks only. Without these quiet stretches the silence
        /// rows — the ones that matter most — would never be reached at a 2 s observation cadence.
        var quietTicksRemaining = 0

        for step in 0..<100_000 {
            // Time usually advances by up to 2 s; one input in fifty arrives out of order.
            if random.int(below: 50) == 0 {
                nanoseconds -= Int64(random.int(in: 0...3_000)) * 1_000_000
            } else {
                nanoseconds += Int64(random.int(in: 0...2_000)) * 1_000_000
            }
            let at = MonotonicInstant(nanoseconds: nanoseconds)
            latestInput = max(latestInput, nanoseconds)

            if quietTicksRemaining == 0, random.int(below: 300) == 0 {
                quietTicksRemaining = random.int(in: 20...60)
            }

            let input: EngineInput
            if quietTicksRemaining > 0 {
                quietTicksRemaining -= 1
                input = .tick(at: at)
            } else {
                switch random.int(below: 100) {
                case 0..<58:
                    let name = random.int(below: 10) == 0 ? "device-Z" : (random.int(below: 2) == 0 ? "device-A" : "device-B")
                    // Mostly plausible dBm, occasionally impossible, so the validator is exercised too.
                    let rssi = random.int(below: 20) == 0 ? random.int(in: -400...400) : random.int(in: -110...(-30))
                    input = .observation(BLEObservation(device: DeviceID(name), at: at, rssi: rssi))
                case 58..<88:
                    input = .tick(at: at)
                case 88..<97:
                    let status: SensorStatus
                    switch random.int(below: 4) {
                    case 0: status = .degraded(.scanInterrupted)
                    case 1: status = .unavailable(.poweredOff)
                    case 2: status = .unavailable(.scannerFailed)
                    default: status = .available
                    }
                    input = .sensor(status, at: at)
                default:
                    let reasons: [ResetReason] = [.systemWake, .bluetoothReset, .sessionChanged, .devicesChanged]
                    input = .reset(reasons[random.int(below: reasons.count)], at: at)
                }
            }

            let transitions = engine.handle(input)
            checker.check(transitions, snapshot: engine.snapshot, step: step, latestInput: latestInput)
        }

        #expect(checker.violations.isEmpty, "\(checker.violations.prefix(5))")
        #expect(checker.presenceTransitions > 100, "the generator must actually exercise the state machine")
        // A run this long must reach the measured *and* the silence rows, not just the reset ones.
        for expected in [
            "unknown|present|confirmedNear",
            "unknown|away|measuredFar",
            "present|departing|signalWeakened",
            "departing|present|signalRecovered",
            "departing|away|measuredFar",
            "present|unknown|evidenceExpired",
            "away|unknown|evidenceExpired",
        ] {
            #expect(checker.seen.contains(expected), "never exercised \(expected)")
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
