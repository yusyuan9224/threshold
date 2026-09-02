import Testing
@testable import ThresholdDiagnostics

@Suite struct ThresholdDiagnosticsModuleTests {
    @Test func moduleLinks() { #expect(ThresholdDiagnosticsModule.name == "ThresholdDiagnostics") }
}
