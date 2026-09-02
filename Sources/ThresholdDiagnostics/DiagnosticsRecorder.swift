import Foundation
import os

/// A point-in-time read of the recorder's ring buffer, cheap enough to poll at 1 Hz from UI.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public let events: [DiagnosticEvent]
    public let droppedCount: Int
    public let totalRecorded: UInt64
    public let generatedAt: Date

    public init(events: [DiagnosticEvent], droppedCount: Int, totalRecorded: UInt64, generatedAt: Date) {
        self.events = events
        self.droppedCount = droppedCount
        self.totalRecorded = totalRecorded
        self.generatedAt = generatedAt
    }
}

/// The exported document shape: `{ "format": "threshold-diagnostics/1", "app": ..., "events": [...] }`.
/// Not `private` so `@testable import` can decode it back in tests without a second public type.
struct DiagnosticsExportEnvelope: Codable {
    let format: String
    let app: String
    let events: [DiagnosticEvent]
}

/// Ingests events from anywhere in the app (via Coordinator subscription in Runtime; see
/// ADR-007) into a bounded, privacy-filtered ring buffer, and exports a de-identified snapshot.
///
/// An actor because diagnostics events can arrive at high frequency from many concurrent
/// producers and must never be routed through `@MainActor` to get there (architecture.md §4.1).
public actor DiagnosticsRecorder {
    private let appVersion: String
    private let logger: Logger?
    private let clock: @Sendable () -> Date

    private var events: RingBuffer<DiagnosticEvent>
    private var nextSequence: UInt64 = 0
    private var droppedCount: Int = 0
    private var totalRecorded: UInt64 = 0
    private var deviceAlias = DeviceAlias()

    public init(
        capacity: Int = 10_000,
        appVersion: String,
        logger: Logger? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.appVersion = appVersion
        self.logger = logger
        self.clock = clock
        self.events = RingBuffer(capacity: capacity)
    }

    /// Records one event: assigns `sequence` and wall clock, runs both the free-form `message` and
    /// `fields` through `PrivacyFilter`, appends to the ring buffer (overwriting the oldest entry if
    /// at capacity), and optionally logs a summary via `os.Logger`.
    ///
    /// Only `category` is logged `.public`: it comes from a closed enum. The message is caller-authored
    /// text and stays `.private` even after redaction, so an unanticipated sensitive shape cannot reach
    /// the system log in the clear.
    public func record(
        category: DiagnosticEvent.Category,
        message: String,
        monotonicNanoseconds: Int64,
        fields: [String: DiagnosticEvent.FieldValue] = [:]
    ) {
        let filteredFields = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        let filteredMessage = PrivacyFilter.redact(message)

        let sequence = nextSequence
        nextSequence += 1
        totalRecorded += 1

        let event = DiagnosticEvent(
            sequence: sequence,
            monotonicNanoseconds: monotonicNanoseconds,
            wallClock: clock(),
            category: category,
            message: filteredMessage,
            fields: filteredFields
        )

        if events.append(event) {
            droppedCount += 1
        }

        logger?.debug("[\(category.rawValue, privacy: .public)] \(filteredMessage, privacy: .private) fields=\(String(describing: filteredFields), privacy: .private)")
    }

    /// The most recent `limit` events, newest last.
    public func snapshot(limit: Int = 200) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            events: events.suffix(limit),
            droppedCount: droppedCount,
            totalRecorded: totalRecorded,
            generatedAt: clock()
        )
    }

    /// De-identified JSON export of every event currently in the ring buffer.
    ///
    /// Fails closed: the encoded bytes are run through `DiagnosticsExportAnonymityCheck`, and if it
    /// finds anything `PrivacyFilter` should have removed, this throws
    /// `DiagnosticsExportError.anonymityViolation` and returns no data at all. An export exists to
    /// be attached to an issue report, so a leak here is a leak off the machine; refusing to export
    /// is always the better failure.
    public func export() throws -> Data {
        let envelope = DiagnosticsExportEnvelope(format: "threshold-diagnostics/1", app: appVersion, events: events.elements)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let findings = DiagnosticsExportAnonymityCheck.findings(in: data)
        guard findings.isEmpty else {
            throw DiagnosticsExportError.anonymityViolation(findings)
        }
        return data
    }

    /// Appends an event without privacy filtering, to exercise `export()`'s fail-closed path.
    ///
    /// Internal and test-only: no production code may reach the buffer except through `record()`,
    /// which filters. Kept here rather than behind a `#if DEBUG` so the shipped build compiles the
    /// same code the tests exercise; `internal` already keeps it out of every other target.
    func appendUnfilteredForTesting(_ event: DiagnosticEvent) {
        if events.append(event) {
            droppedCount += 1
        }
        totalRecorded += 1
    }
}
