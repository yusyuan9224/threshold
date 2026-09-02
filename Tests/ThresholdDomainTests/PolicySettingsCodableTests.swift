import Testing
import Foundation
@testable import ThresholdDomain

@Suite("PolicySettings — persistence contract")
struct PolicySettingsCodableTests {
    @Test func roundTripsThroughJSONIncludingTheSilenceLockPolicy() throws {
        var settings = PolicySettings()
        settings.autoLock = false
        settings.silenceLock = .afterTimeout(.seconds(42))
        settings.wakeWindow = .milliseconds(1500)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PolicySettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func neverPolicyRoundTrips() throws {
        var settings = PolicySettings()
        settings.silenceLock = .never
        let decoded = try JSONDecoder().decode(PolicySettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.silenceLock == .never)
    }
}
