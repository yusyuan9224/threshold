import Foundation

/// A single, flat, greppable diagnostics record.
///
/// `ThresholdDiagnostics` depends only on Foundation and os.log (ADR-007), so this schema is
/// plain strings/numbers rather than Domain types — the Runtime layer maps Domain values into
/// this schema. `wallClock` is attached only here, at ingestion (`DiagnosticsRecorder`); no other
/// layer in the app may read wall-clock time into a diagnostics record.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    /// What kind of thing happened. Mirrors the areas ADR-007 says must be recordable.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case bleObservation
        case signalEstimate
        case presenceScore
        case transition
        case policyEvaluation
        case actionDispatched
        case actionOutcome
        case systemLifecycle
        case bluetoothLifecycle
        case calibration
        case securityDenial
    }

    /// A small closed set of value kinds for `fields`, kept flat and Codable without `Any`.
    public enum FieldValue: Sendable, Equatable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
    }

    /// Assigned by the recorder; strictly increasing per recorder instance.
    public let sequence: UInt64
    /// Monotonic time carried in from the caller (see `MonotonicClock` elsewhere in Threshold).
    public let monotonicNanoseconds: Int64
    /// Wall-clock time attached by `DiagnosticsRecorder` at ingestion — the only place it appears.
    public let wallClock: Date
    public let category: Category
    public let message: String
    /// Already privacy-filtered by the time an event exists (see `PrivacyFilter`).
    public let fields: [String: FieldValue]

    public init(
        sequence: UInt64,
        monotonicNanoseconds: Int64,
        wallClock: Date,
        category: Category,
        message: String,
        fields: [String: FieldValue]
    ) {
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.wallClock = wallClock
        self.category = category
        self.message = message
        self.fields = fields
    }
}

extension DiagnosticEvent.FieldValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case int
        case double
        case bool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .int: self = .int(try container.decode(Int64.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Kind.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(Kind.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
