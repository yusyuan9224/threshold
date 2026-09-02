import Testing
@testable import ThresholdDiagnostics

@Suite struct PrivacyFilterTests {
    @Test func redactsPasswordLikeKeys() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = ["password": .string("hunter2")]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["password"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsCredentialAndPasscodeKeys() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = [
            "userCredential": .string("secret"),
            "unlockPasscode": .string("1234"),
        ]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["userCredential"] == nil)
        #expect(filtered["unlockPasscode"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsUUIDShapedValues() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = ["note": .string("id 123E4567-E89B-12D3-A456-426614174000 seen")]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["note"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsMACAddressValues() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = ["raw": .string("AA:BB:CC:DD:EE:FF")]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["raw"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsEmailValues() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = ["contact": .string("person@example.com")]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["contact"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func aliasesDeviceRelatedKeysConsistently() {
        var deviceAlias = DeviceAlias()
        let first = PrivacyFilter.apply(to: ["deviceID": .string("AA:BB:CC:DD:EE:FF")], deviceAlias: &deviceAlias)
        let second = PrivacyFilter.apply(to: ["peripheralIdentifier": .string("AA:BB:CC:DD:EE:FF")], deviceAlias: &deviceAlias)
        guard case .string(let firstAlias)? = first["deviceID"],
              case .string(let secondAlias)? = second["peripheralIdentifier"] else {
            Issue.record("expected aliased string values")
            return
        }
        #expect(firstAlias == secondAlias)
        #expect(firstAlias.hasPrefix("device-"))
    }

    /// ADR-007 replaces device identity with a stable short alias — a device *name* ("Someone's
    /// iPhone") identifies the device just as well as its address, so it is aliased, not passed on.
    @Test func aliasesDeviceAndPeripheralNameKeys() {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(
            to: ["deviceName": .string("Someone's iPhone"), "peripheralName": .string("Someone's iPad")],
            deviceAlias: &deviceAlias
        )
        guard case .string(let deviceValue)? = filtered["deviceName"],
              case .string(let peripheralValue)? = filtered["peripheralName"] else {
            Issue.record("expected aliased string values")
            return
        }
        #expect(deviceValue.hasPrefix("device-"))
        #expect(peripheralValue.hasPrefix("device-"))
        #expect(deviceValue != peripheralValue)
    }

    @Test(arguments: ["localName", "hostname", "host", "serialNumber", "userName", "appleID", "accountLabel"])
    func redactsNameShapedKeys(key: String) {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(to: [key: .string("Someone")], deviceAlias: &deviceAlias)
        #expect(filtered[key] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    /// ADR-006 lifecycle IDs are correlation handles, not device identity: aliasing them would make
    /// two different actions look like the same device.
    @Test(arguments: ["actionIdentifier", "episodeIdentifier", "transitionIdentifier"])
    func neverAliasesLifecycleIdentifiers(key: String) {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(to: [key: .string("a1b2")], deviceAlias: &deviceAlias)
        #expect(filtered[key] == .string("a1b2"))
        #expect(filtered["redacted"] == nil)
    }

    @Test func redactsLocalHostnameShapedValues() {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(to: ["note": .string("resolved host.local")], deviceAlias: &deviceAlias)
        #expect(filtered["note"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsOwnerNamedDeviceValues() {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(to: ["note": .string("saw Someone's iPhone")], deviceAlias: &deviceAlias)
        #expect(filtered["note"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func redactsHomePathValues() {
        var deviceAlias = DeviceAlias()
        let filtered = PrivacyFilter.apply(to: ["note": .string("/Users/yusyuan/x.json")], deviceAlias: &deviceAlias)
        #expect(filtered["note"] == nil)
        #expect(filtered["redacted"] == .bool(true))
    }

    @Test func aliasesDifferentRawIdentifiersDifferently() {
        var deviceAlias = DeviceAlias()
        let first = PrivacyFilter.apply(to: ["device": .string("raw-one")], deviceAlias: &deviceAlias)
        let second = PrivacyFilter.apply(to: ["device": .string("raw-two")], deviceAlias: &deviceAlias)
        #expect(first["device"] != second["device"])
    }

    @Test func passesThroughOrdinaryFields() {
        var deviceAlias = DeviceAlias()
        let fields: [String: DiagnosticEvent.FieldValue] = ["rssi": .int(-62), "healthy": .bool(true)]
        let filtered = PrivacyFilter.apply(to: fields, deviceAlias: &deviceAlias)
        #expect(filtered["rssi"] == .int(-62))
        #expect(filtered["healthy"] == .bool(true))
        #expect(filtered["redacted"] == nil)
    }
}
