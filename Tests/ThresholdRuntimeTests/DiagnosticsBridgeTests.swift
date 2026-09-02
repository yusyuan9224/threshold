import Foundation
import Testing
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdRuntime

/// The Runtime end of ADR-007: Coordinator events become diagnostics records, and nothing that
/// identifies a device survives the trip.
@Suite struct DiagnosticsBridgeTests {

    /// A full departure-and-lock run, recorded end to end. `export()` fails closed on anything the
    /// privacy filter should have removed, so a clean export is itself the anonymity assertion.
    @Test func aRecordedRunExportsCleanlyAndCoversEveryArea() async throws {
        let recorder = DiagnosticsRecorder(appVersion: "threshold-tests")
        let harness = RuntimeHarness(diagnostics: recorder)
        await harness.start()

        await harness.driveToAway()
        #expect(await waitUntil { harness.lock.lockCount == 1 })
        // Silence the device so the third axis produces a transition too, which is the only event
        // carrying a raw `DeviceID` into the bridge.
        await harness.tick(31)

        // The wait must cover the aliased device field too: the categories alone are satisfied
        // before the device-axis transition has been drained, and exporting then races it.
        #expect(await waitUntil {
            let events = await recorder.snapshot(limit: 2000).events
            let categories = Set(events.map(\.category))
            return categories.isSuperset(of: [.transition, .policyEvaluation, .actionDispatched, .actionOutcome])
                && events.contains { $0.fields["device"] != nil }
        })

        let data = try await recorder.export()
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains(deviceA.raw), "the raw device identifier must never reach an export")
        #expect(text.contains("device-1"), "it is present, as a stable alias")

        let events = await recorder.snapshot(limit: 2000).events
        #expect(events.contains { $0.category == .transition && $0.message.contains("away") })
        #expect(events.contains { $0.category == .actionDispatched })
        #expect(events.contains { $0.category == .presenceScore })
    }

    /// Wall-clock time belongs to the recorder. The bridge passes on the monotonic instant the
    /// event already carries, so a transition is recorded at the instant it happened rather than at
    /// the instant it was written.
    @Test func transitionsAreRecordedAtTheirOwnMonotonicInstant() async {
        let recorder = DiagnosticsRecorder(appVersion: "threshold-tests")
        let harness = RuntimeHarness(diagnostics: recorder)
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)

        #expect(await waitUntil {
            await recorder.snapshot(limit: 500).events.contains {
                $0.category == .transition && $0.monotonicNanoseconds == at(6).nanoseconds
            }
        })
    }

    /// The lifecycle and restart channels are recorded under the categories ADR-007 names for them.
    @Test func lifecycleAndScannerRestartsAreRecorded() async {
        let recorder = DiagnosticsRecorder(appVersion: "threshold-tests")
        let bridge = DiagnosticsBridge(recorder: recorder, clock: FakeClock(start: at(0)))

        await bridge.record(.lifecycle(.systemDidWake))
        await bridge.record(.sensorRestart(attempt: 2))

        let events = await recorder.snapshot(limit: 10).events
        #expect(events.contains { $0.category == .systemLifecycle && $0.message == "systemDidWake" })
        #expect(events.contains { $0.category == .bluetoothLifecycle && $0.fields["attempt"] == .int(2) })
    }
}
