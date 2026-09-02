import Testing
@testable import ThresholdDiagnostics

@Suite struct DeviceAliasTests {
    @Test func sameRawProducesSameAlias() {
        var deviceAlias = DeviceAlias()
        let first = deviceAlias.alias(for: "AA:BB:CC:DD:EE:FF")
        let second = deviceAlias.alias(for: "AA:BB:CC:DD:EE:FF")
        #expect(first == second)
    }

    @Test func differentRawProducesDifferentAlias() {
        var deviceAlias = DeviceAlias()
        let first = deviceAlias.alias(for: "device-raw-1")
        let second = deviceAlias.alias(for: "device-raw-2")
        #expect(first != second)
    }

    @Test func aliasesFollowSequentialPerInstancePattern() {
        var deviceAlias = DeviceAlias()
        #expect(deviceAlias.alias(for: "a") == "device-1")
        #expect(deviceAlias.alias(for: "b") == "device-2")
        #expect(deviceAlias.alias(for: "a") == "device-1")
    }
}
