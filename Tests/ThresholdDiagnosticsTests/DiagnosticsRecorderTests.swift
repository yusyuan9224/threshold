import Testing
import Foundation
@testable import ThresholdDiagnostics

@Suite struct DiagnosticsRecorderTests {
    @Test func ringBufferDropsOldestAndReportsDroppedCount() async {
        let recorder = DiagnosticsRecorder(capacity: 3, appVersion: "1.0.0-test")
        for i in 0..<5 {
            await recorder.record(category: .systemLifecycle, message: "event-\(i)", monotonicNanoseconds: Int64(i))
        }
        let snapshot = await recorder.snapshot(limit: 10)
        #expect(snapshot.events.count == 3)
        #expect(snapshot.droppedCount == 2)
        #expect(snapshot.totalRecorded == 5)
        #expect(snapshot.events.map(\.message) == ["event-2", "event-3", "event-4"])
    }

    @Test func sequenceStrictlyIncreases() async {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "1.0.0-test")
        for i in 0..<5 {
            await recorder.record(category: .calibration, message: "m\(i)", monotonicNanoseconds: 0)
        }
        let snapshot = await recorder.snapshot(limit: 10)
        #expect(snapshot.events.map(\.sequence) == [0, 1, 2, 3, 4])
    }

    @Test func snapshotRespectsLimit() async {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "1.0.0-test")
        for i in 0..<10 {
            await recorder.record(category: .transition, message: "m\(i)", monotonicNanoseconds: 0)
        }
        let snapshot = await recorder.snapshot(limit: 4)
        #expect(snapshot.events.count == 4)
        #expect(snapshot.events.map(\.message) == ["m6", "m7", "m8", "m9"])
    }

    @Test func exportDecodesBackToSameEvents() async throws {
        let recorder = DiagnosticsRecorder(capacity: 10, appVersion: "9.9.9")
        await recorder.record(
            category: .policyEvaluation,
            message: "decided",
            monotonicNanoseconds: 42,
            fields: ["confidence": .double(0.87)]
        )
        let data = try await recorder.export()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsExportEnvelope.self, from: data)
        #expect(decoded.format == "threshold-diagnostics/1")
        #expect(decoded.app == "9.9.9")
        #expect(decoded.events.count == 1)
        #expect(decoded.events[0].message == "decided")
        #expect(decoded.events[0].category == .policyEvaluation)
        #expect(decoded.events[0].monotonicNanoseconds == 42)
        #expect(decoded.events[0].fields["confidence"] == .double(0.87))
    }

    @Test func actorIsolationHandles10000ConcurrentRecords() async {
        let recorder = DiagnosticsRecorder(appVersion: "1.0.0-test")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10_000 {
                group.addTask {
                    await recorder.record(category: .bleObservation, message: "obs", monotonicNanoseconds: Int64(i))
                }
            }
        }
        let snapshot = await recorder.snapshot(limit: 1)
        #expect(snapshot.totalRecorded == 10_000)
        #expect(snapshot.droppedCount == 0)
    }
}
