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

    @Test func aliasesIdentifierSuffixedKeysConsistently() {
        var deviceAlias = DeviceAlias()
        let first = PrivacyFilter.apply(to: ["deviceID": .string("AA:BB:CC:DD:EE:FF")], deviceAlias: &deviceAlias)
        let second = PrivacyFilter.apply(to: ["peerIdentifier": .string("AA:BB:CC:DD:EE:FF")], deviceAlias: &deviceAlias)
        guard case .string(let firstAlias)? = first["deviceID"], case .string(let secondAlias)? = second["peerIdentifier"] else {
            Issue.record("expected aliased string values")
            return
        }
        #expect(firstAlias == secondAlias)
        #expect(firstAlias.hasPrefix("device-"))
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
