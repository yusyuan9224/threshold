import Testing
import Foundation
@testable import ThresholdDiagnostics

/// ADR-007 forbids raw identifiers/MACs/hostnames anywhere in diagnostics — the free-form
/// `message` is no less exported than `fields`, so it goes through the same redaction.
@Suite struct PrivacyFilterMessageTests {
    @Test func redactsUUIDInMessage() {
        let redacted = PrivacyFilter.redact("peer 123E4567-E89B-12D3-A456-426614174000 connected")
        #expect(!redacted.contains("123E4567-E89B-12D3-A456-426614174000"))
        #expect(redacted == "peer <redacted:uuid> connected")
    }

    @Test func redactsMACAddressInMessage() {
        let redacted = PrivacyFilter.redact("advertisement from AA:BB:CC:DD:EE:FF")
        #expect(!redacted.contains("AA:BB:CC:DD:EE:FF"))
        #expect(redacted == "advertisement from <redacted:mac>")
    }

    @Test func redactsEmailInMessage() {
        let redacted = PrivacyFilter.redact("owner person@example.com")
        #expect(!redacted.contains("person@example.com"))
        #expect(redacted == "owner <redacted:email>")
    }

    @Test func redactsLocalHostnameInMessage() {
        let redacted = PrivacyFilter.redact("resolved host.local ok")
        #expect(!redacted.contains("host.local"))
        #expect(redacted == "resolved <redacted:hostname> ok")
    }

    @Test func redactsPossessiveDeviceNameInMessage() {
        let redacted = PrivacyFilter.redact("saw Someone's iPhone nearby")
        #expect(!redacted.contains("Someone's iPhone"))
        #expect(redacted == "saw <redacted:device-name> nearby")
    }

    @Test func redactsPossessiveDeviceNameVariants() {
        #expect(PrivacyFilter.redact("Someone's MacBook Pro") == "<redacted:device-name>")
        #expect(PrivacyFilter.redact("Someone's Apple Watch") == "<redacted:device-name>")
        #expect(PrivacyFilter.redact("Someone’s iPad") == "<redacted:device-name>")
    }

    @Test func redactsHomePathInMessage() {
        let redacted = PrivacyFilter.redact("loaded /Users/yusyuan/profile.json")
        #expect(!redacted.contains("/Users/yusyuan"))
        #expect(!redacted.contains("/Users/"))
    }

    @Test func redactionTokensAreStableAcrossCalls() {
        let first = PrivacyFilter.redact("id 123E4567-E89B-12D3-A456-426614174000")
        let second = PrivacyFilter.redact("id 123E4567-E89B-12D3-A456-426614174000")
        let other = PrivacyFilter.redact("id 00000000-0000-4000-8000-000000000000")
        #expect(first == second)
        #expect(first == other)
    }

    @Test func redactsEveryShapeInOneMessage() {
        let message = "Someone's iPhone 123E4567-E89B-12D3-A456-426614174000 AA:BB:CC:DD:EE:FF host.local"
        let redacted = PrivacyFilter.redact(message)
        #expect(!redacted.contains("Someone's iPhone"))
        #expect(!redacted.contains("123E4567-E89B-12D3-A456-426614174000"))
        #expect(!redacted.contains("AA:BB:CC:DD:EE:FF"))
        #expect(!redacted.contains("host.local"))
        #expect(DiagnosticsExportAnonymityCheck.findings(in: Data(redacted.utf8)).isEmpty)
    }

    @Test func leavesOrdinaryMessageUnchanged() {
        let message = "presence state changed to near (confidence 0.87)"
        #expect(PrivacyFilter.redact(message) == message)
    }
}
