import Testing
@testable import ThresholdAppKit

@Suite struct ThresholdAppKitModuleTests {
    @Test func moduleLinks() { #expect(SupportedDevices.shortNote.isEmpty == false) }
}
