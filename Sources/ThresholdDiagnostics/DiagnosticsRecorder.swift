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
    private let capacity: Int
    private let appVersion: String
    private let logger: Logger?
    private let clock: @Sendable () -> Date

    private var events: [DiagnosticEvent] = []
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
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.appVersion = appVersion
        self.logger = logger
        self.clock = clock
        self.events.reserveCapacity(capacity)
    }

    /// Records one event: assigns `sequence` and wall clock, applies `PrivacyFilter`, appends to
    /// the ring buffer (dropping the oldest entry if at capacity), and optionally logs a redacted
    /// summary via `os.Logger` (category/message `.public`, fields `.private`).
    public func record(
        category: DiagnosticEvent.Category,
        message: String,
        monotonicNanoseconds: Int64,
        fields: [String: DiagnosticEvent.FieldValue] = [:]
    ) {
        let filteredFields = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)

        let sequence = nextSequence
        nextSequence += 1
        totalRecorded += 1

        let event = DiagnosticEvent(
            sequence: sequence,
            monotonicNanoseconds: monotonicNanoseconds,
            wallClock: clock(),
            category: category,
            message: message,
            fields: filteredFields
        )

        events.append(event)
        if events.count > capacity {
            events.removeFirst()
            droppedCount += 1
        }

        logger?.debug("[\(category.rawValue, privacy: .public)] \(message, privacy: .public) fields=\(String(describing: filteredFields), privacy: .private)")
    }

    /// The most recent `limit` events, newest last.
    public func snapshot(limit: Int = 200) -> DiagnosticsSnapshot {
        let recent = limit > 0 ? events.suffix(limit) : []
        return DiagnosticsSnapshot(
            events: Array(recent),
            droppedCount: droppedCount,
            totalRecorded: totalRecorded,
            generatedAt: clock()
        )
    }

    /// De-identified JSON export of every event currently in the ring buffer.
    public func export() throws -> Data {
        let envelope = DiagnosticsExportEnvelope(format: "threshold-diagnostics/1", app: appVersion, events: events)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }
}
