import Testing
@testable import ThresholdRuntime

@Suite struct ThresholdRuntimeModuleTests {
    @Test func moduleLinks() { #expect(ThresholdRuntimeModule.name == "ThresholdRuntime") }
}
