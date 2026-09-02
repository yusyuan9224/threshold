import Testing
@testable import ThresholdSystem

@Suite struct ThresholdSystemModuleTests {
    @Test func moduleLinks() { #expect(ThresholdSystemModule.name == "ThresholdSystem") }
}
