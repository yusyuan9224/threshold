import Testing
import Foundation
@testable import ThresholdDiagnostics

@Suite struct DiagnosticsExportAnonymityCheckTests {
    @Test func findsNothingInNormalExport() async throws {
        let recorder = DiagnosticsRecorder(appVersion: "1.0.0-test")
        await recorder.record(
            category: .systemLifecycle,
            message: "launched",
            monotonicNanoseconds: 0,
            fields: ["deviceID": .string("AA:BB:CC:DD:EE:FF")]
        )
        let data = try await recorder.export()
        #expect(DiagnosticsExportAnonymityCheck.findings(in: data).isEmpty)
    }

    @Test func findsPlantedUUID() {
        let json = Data(#"{"format":"threshold-diagnostics/1","app":"x","events":[{"note":"123E4567-E89B-12D3-A456-426614174000"}]}"#.utf8)
        let findings = DiagnosticsExportAnonymityCheck.findings(in: json)
        #expect(findings.contains { $0.localizedCaseInsensitiveContains("uuid") })
    }

    @Test func findsPlantedMACAddress() {
        let json = Data(#"{"note":"AA:BB:CC:DD:EE:FF"}"#.utf8)
        let findings = DiagnosticsExportAnonymityCheck.findings(in: json)
        #expect(findings.contains { $0.localizedCaseInsensitiveContains("mac") })
    }

    @Test func findsPlantedEmail() {
        let json = Data(#"{"note":"person@example.com"}"#.utf8)
        #expect(!DiagnosticsExportAnonymityCheck.findings(in: json).isEmpty)
    }

    @Test func findsPlantedLocalHostname() {
        let json = Data(#"{"note":"Yus-MacBook.local"}"#.utf8)
        #expect(!DiagnosticsExportAnonymityCheck.findings(in: json).isEmpty)
    }

    @Test func findsPlantedHomePath() {
        let json = Data(#"{"note":"/Users/yusyuan/secret.txt"}"#.utf8)
        #expect(!DiagnosticsExportAnonymityCheck.findings(in: json).isEmpty)
    }
}
