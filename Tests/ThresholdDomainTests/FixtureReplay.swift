import Foundation
import Testing
@testable import ThresholdDomain

// L2 fixture replay support (docs/specs/testing.md §1, §3).
//
// Foundation lives here and only here: the test target may import it, `ThresholdDomain` may not.
// The decoder is deliberately small and strict — a fixture that does not parse is a broken
// fixture, not a skipped test.

/// First line of every fixture.
struct FixtureMeta: Decodable {
    let kind: String
    let macClass: String
    let deviceClass: String
    let scenario: String
    let recorder: String
    let anonymized: Bool
    /// The calibration the recording was made under. Goldens depend on it, so it travels with
    /// the fixture rather than living in test code.
    let profile: FixtureProfile?

    struct FixtureProfile: Decodable {
        let nearBaseline: Double
        let farBaseline: Double
        let noise: Double
        let midpoint: Double
        let slope: Double

        var calibrationProfile: CalibrationProfile {
            CalibrationProfile(nearBaseline: nearBaseline, farBaseline: farBaseline, noise: noise, midpoint: midpoint, slope: slope)
        }
    }
}

/// Every line after the first. `t` is milliseconds relative to t0.
struct FixtureLine: Decodable {
    let kind: String
    let t: Int64?
    let device: String?
    let rssi: Int?
    let status: String?
    let reason: String?

    var instant: MonotonicInstant { MonotonicInstant(nanoseconds: (t ?? 0) * 1_000_000) }

    /// `nil` for a line that is not an input. `Tools/rssi-record` closes a recording with a
    /// `summary` line of capture metrics, which the replay skips rather than rejects.
    func engineInput() throws -> EngineInput? {
        switch kind {
        case "summary":
            return nil
        case "observation":
            guard let device, let rssi else { throw FixtureError.malformed("observation without device/rssi at t=\(timeLabel)") }
            return .observation(BLEObservation(device: DeviceID(device), at: instant, rssi: rssi))
        case "tick":
            return .tick(at: instant)
        case "sensor":
            return .sensor(try sensorStatus(), at: instant)
        case "reset":
            guard let reason, let parsed = ResetReason(rawValue: reason) else {
                throw FixtureError.malformed("unknown reset reason \(reason ?? "nil") at t=\(timeLabel)")
            }
            return .reset(parsed, at: instant)
        default:
            throw FixtureError.malformed("unknown line kind \(kind) at t=\(timeLabel)")
        }
    }

    /// `available`, or `<case>.<reason.rawValue>` — the exact spellings `Tools/rssi-record` writes.
    /// Pinned by hand rather than derived from `Codable` synthesis, so the file format cannot drift
    /// when the Domain's enums change shape.
    private func sensorStatus() throws -> SensorStatus {
        switch status {
        case "available": return .available
        case "degraded.resetting": return .degraded(.resetting)
        case "degraded.scanInterrupted": return .degraded(.scanInterrupted)
        case "unavailable.poweredOff": return .unavailable(.poweredOff)
        case "unavailable.unauthorized": return .unavailable(.unauthorized)
        case "unavailable.unsupported": return .unavailable(.unsupported)
        case "unavailable.scannerFailed": return .unavailable(.scannerFailed)
        default: throw FixtureError.malformed("unknown sensor status \(status ?? "nil") at t=\(timeLabel)")
        }
    }

    private var timeLabel: String { t.map(String.init) ?? "unset" }
}

/// Golden file: the presence-axis transitions the engine must produce for this recording.
struct FixtureGolden: Codable, Equatable {
    struct Transition: Codable, Equatable {
        let at: Int64
        let from: String
        let to: String
        let cause: String
    }
    struct Final: Codable, Equatable {
        let presence: String
        let evidence: String
    }
    let scenario: String
    let transitions: [Transition]
    let final: Final
}

enum FixtureError: Error, CustomStringConvertible {
    case malformed(String)
    case missingResource(String)

    var description: String {
        switch self {
        case .malformed(let detail): return "malformed fixture: \(detail)"
        case .missingResource(let name): return "fixture resource not found: \(name)"
        }
    }
}

/// Labels used in golden files. Kept separate from the Domain's diagnostic labels for causes so a
/// golden reads as a recording of behaviour rather than of an enum's spelling.
func goldenCauseLabel(_ cause: TransitionCause) -> String {
    switch cause {
    case .confirmedNear: return "confirmedNear"
    case .measuredFar: return "measuredFar"
    case .signalWeakened: return "signalWeakened"
    case .signalRecovered: return "signalRecovered"
    case .departureThenSilent: return "departureThenSilent"
    case .evidenceExpired: return "evidenceExpired"
    case .reset(let reason): return "reset(\(reason.rawValue))"
    case .sensorRestored: return "sensorRestored"
    case .sensorBecameHealthy: return "sensorBecameHealthy"
    case .sensorDegraded(let reason): return "sensorDegraded(\(reason.rawValue))"
    case .sensorUnavailable(let reason): return "sensorUnavailable(\(reason.rawValue))"
    case .sensorInitializing: return "sensorInitializing"
    case .deviceSilent: return "deviceSilent"
    case .deviceReceiving: return "deviceReceiving"
    }
}

func goldenEvidenceLabel(_ evidence: PresenceEvidence) -> String {
    switch evidence {
    case .none: return "none"
    case .measuredNear: return "measuredNear"
    case .measuredFar: return "measuredFar"
    case .departureThenSilent: return "departureThenSilent"
    }
}

/// Every fixture in `Tests/Fixtures/BLE`, by scenario name.
enum Fixtures {
    /// Discovered from the bundle rather than hard-coded, so a recording dropped in by
    /// `Tools/rssi-record` is replayed without anyone remembering to add it to a list.
    /// `requiredScenarios` is the guard against this silently finding nothing.
    static let names: [String] = {
        guard let directory = try? directory(),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return entries.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(".jsonl".count)) }.sorted()
    }()

    /// The minimum regression set named by docs/specs/testing.md §3.
    static let requiredScenarios = [
        "bluetooth-off",
        "departure-then-silent",
        "device-lost",
        "signal-spike",
        "stable-away",
        "stable-near",
        "sudden-silence-at-desk",
        "wake-after-sleep",
        "walking-away",
        "walking-back",
        "wifi-interference",
    ]

    static func directory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "BLE", withExtension: nil) else {
            throw FixtureError.missingResource("BLE directory (check the resources rule in Package.swift)")
        }
        return url
    }

    static func url(_ name: String, extension ext: String) throws -> URL {
        try directory().appendingPathComponent("\(name).\(ext)")
    }

    /// Parses one recording into its metadata and its inputs, in file order.
    static func load(_ name: String) throws -> (meta: FixtureMeta, inputs: [EngineInput]) {
        let contents = try String(contentsOf: try url(name, extension: "jsonl"), encoding: .utf8)
        let lines = contents.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.first else { throw FixtureError.malformed("\(name) is empty") }

        let decoder = JSONDecoder()
        let meta = try decoder.decode(FixtureMeta.self, from: Data(first.utf8))
        guard meta.kind == "meta" else { throw FixtureError.malformed("\(name) does not start with a meta line") }

        let inputs = try lines.dropFirst().compactMap { line in
            try decoder.decode(FixtureLine.self, from: Data(line.utf8)).engineInput()
        }
        return (meta, inputs)
    }

    static func golden(_ name: String) throws -> FixtureGolden {
        let data = try Data(contentsOf: try url(name, extension: "expected.json"))
        return try JSONDecoder().decode(FixtureGolden.self, from: data)
    }

    /// Replays one recording through a fresh engine and reduces it to the golden shape.
    static func replay(_ name: String) throws -> FixtureGolden {
        let (meta, inputs) = try load(name)
        let profile = meta.profile?.calibrationProfile ?? .default
        var devices: Set<DeviceID> = []
        for case .observation(let observation) in inputs { devices.insert(observation.device) }
        var engine = ProximityEngine(
            fusion: AnyDeviceFusion(),
            devices: devices.isEmpty ? [DeviceID("device-A")] : devices,
            gate: .armed(profile)
        )
        var transitions: [FixtureGolden.Transition] = []
        for input in inputs {
            for transition in engine.handle(input) where transition.axis == .presence {
                transitions.append(FixtureGolden.Transition(
                    at: transition.at.nanoseconds / 1_000_000,
                    from: transition.from,
                    to: transition.to,
                    cause: goldenCauseLabel(transition.cause)
                ))
            }
        }
        let snapshot = engine.snapshot
        return FixtureGolden(
            scenario: meta.scenario,
            transitions: transitions,
            final: FixtureGolden.Final(
                presence: snapshot.presence.label,
                evidence: goldenEvidenceLabel(snapshot.evidence)
            )
        )
    }
}
