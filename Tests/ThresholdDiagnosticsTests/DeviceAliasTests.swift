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

    /// The alias table is keyed on the raw value itself, so two distinct devices can never collide
    /// onto one alias and be read as the same device in a diagnostics trace.
    @Test func distinctRawValuesNeverShareAnAlias() {
        var deviceAlias = DeviceAlias()
        let raws = (0..<2_000).map { "AA:BB:CC:DD:\($0 / 256):\($0 % 256)" }
        let aliases = raws.map { deviceAlias.alias(for: $0) }
        #expect(Set(aliases).count == raws.count)
    }

    @Test func repeatedLookupsDoNotAllocateNewAliases() {
        var deviceAlias = DeviceAlias()
        for _ in 0..<10 {
            _ = deviceAlias.alias(for: "raw-a")
            _ = deviceAlias.alias(for: "raw-b")
        }
        #expect(deviceAlias.alias(for: "raw-c") == "device-3")
    }

    /// The table holds raw identifiers in memory; nothing that describes it may hand them back out.
    @Test func descriptionsNeverRevealRawValues() {
        var deviceAlias = DeviceAlias()
        _ = deviceAlias.alias(for: "AA:BB:CC:DD:EE:FF")
        #expect(!String(describing: deviceAlias).contains("AA:BB:CC:DD:EE:FF"))
        #expect(!String(reflecting: deviceAlias).contains("AA:BB:CC:DD:EE:FF"))
    }

    @Test func aliasesFollowSequentialPerInstancePattern() {
        var deviceAlias = DeviceAlias()
        #expect(deviceAlias.alias(for: "a") == "device-1")
        #expect(deviceAlias.alias(for: "b") == "device-2")
        #expect(deviceAlias.alias(for: "a") == "device-1")
    }
}
