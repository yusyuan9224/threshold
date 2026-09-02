import Testing
@testable import ThresholdBluetooth

@Suite struct ThresholdBluetoothModuleTests {
    @Test func moduleLinks() { #expect(ThresholdBluetoothModule.name == "ThresholdBluetooth") }
}
