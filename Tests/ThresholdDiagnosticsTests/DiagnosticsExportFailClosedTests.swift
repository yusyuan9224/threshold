import Testing
import Foundation
@testable import ThresholdDiagnostics

/// `DiagnosticsExportAnonymityCheck` is the last line of defense before an export is attached to an
/// issue report. It is only a defense if `export()` actually runs it and refuses to hand back bytes
/// that fail it.
@Suite struct DiagnosticsExportFailClosedTests {
    /// Bypasses `record()` to plant identity the privacy filter would normally have removed,
    /// standing in for any future path that reaches the buffer without being filtered.
    private func recorderWithUnfilteredEvent(message: String) async -> DiagnosticsRecorder {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "1.0.0-test")
        await recorder.appendUnfilteredForTesting(
            DiagnosticEvent(
                sequence: 0,
                monotonicNanoseconds: 0,
                wallClock: Date(timeIntervalSince1970: 0),
                category: .bleObservation,
                message: message,
                fields: [:]
            )
        )
        return recorder
    }

    @Test func exportThrowsWhenAnEventCarriesARawUUID() async throws {
        let recorder = await recorderWithUnfilteredEvent(message: "peer 123E4567-E89B-12D3-A456-426614174000")
        await #expect(throws: DiagnosticsExportError.self) {
            try await recorder.export()
        }
    }

    @Test func exportErrorCarriesTheFindings() async {
        let recorder = await recorderWithUnfilteredEvent(message: "peer 123E4567-E89B-12D3-A456-426614174000")
        do {
            _ = try await recorder.export()
            Issue.record("expected export to fail closed")
        } catch let error as DiagnosticsExportError {
            guard case .anonymityViolation(let findings) = error else {
                Issue.record("unexpected error case: \(error)")
                return
            }
            #expect(findings.contains { $0.localizedCaseInsensitiveContains("uuid") })
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func exportThrowsForEveryCatalogedShape() async throws {
        let messages = [
            "AA:BB:CC:DD:EE:FF",
            "person@example.com",
            "host.local",
            "Someone's iPhone",
            "/Users/someone/notes.txt",
        ]
        for message in messages {
            let recorder = await recorderWithUnfilteredEvent(message: message)
            await #expect(throws: DiagnosticsExportError.self, "\(message) should fail the export check") {
                try await recorder.export()
            }
        }
    }

    @Test func exportSucceedsOnACleanBuffer() async throws {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "1.0.0-test")
        await recorder.record(
            category: .transition,
            message: "near -> far",
            monotonicNanoseconds: 7,
            fields: ["deviceID": .string("AA:BB:CC:DD:EE:FF"), "confidence": .double(0.4)]
        )
        let data = try await recorder.export()
        #expect(!data.isEmpty)
        #expect(DiagnosticsExportAnonymityCheck.findings(in: data).isEmpty)
    }

    /// A message that only *reached* the recorder through `record()` is filtered on the way in, so
    /// the fail-closed path never fires for ordinary traffic.
    @Test func recordedEventsNeverTripTheCheck() async throws {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "1.0.0-test")
        await recorder.record(
            category: .bleObservation,
            message: "Someone's iPhone at AA:BB:CC:DD:EE:FF / host.local / /Users/someone/x",
            monotonicNanoseconds: 0
        )
        let data = try await recorder.export()
        #expect(DiagnosticsExportAnonymityCheck.findings(in: data).isEmpty)
    }
}
