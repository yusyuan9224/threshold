import ServiceManagement
import Testing
import ThresholdDomain
@testable import ThresholdSystem

@Suite struct SpyWakeControllerTests {
    @Test func countsCalls() async throws {
        let spy = SpyWakeController()
        try await spy.wakeDisplay()
        try await spy.wakeDisplay()
        #expect(spy.wakeCount == 2)
    }

    @Test func canBeToldToFail() async throws {
        let spy = SpyWakeController(failure: .assertionFailed(-1))
        await #expect(throws: WakeError.assertionFailed(-1)) { try await spy.wakeDisplay() }
        #expect(spy.wakeCount == 1)

        spy.stopFailing()
        try await spy.wakeDisplay()
        #expect(spy.wakeCount == 2)
    }
}

/// L4 mapping test: `SMAppService.Status` is the only part of the login-item surface that can be
/// exercised without an installed app bundle.
@Suite struct LoginItemStatusMappingTests {
    @Test func mapsEveryKnownStatus() {
        #expect(LoginItemStatusMapping.status(for: .enabled) == .enabled)
        #expect(LoginItemStatusMapping.status(for: .notRegistered) == .notRegistered)
        #expect(LoginItemStatusMapping.status(for: .requiresApproval) == .requiresApproval)
        #expect(LoginItemStatusMapping.status(for: .notFound) == .notFound)
    }
}

@Suite struct FakeLoginItemControllerTests {
    @Test func registerAndUnregisterMoveTheStatus() throws {
        let fake = FakeLoginItemController()
        #expect(fake.status == .notRegistered)

        try fake.register()
        #expect(fake.status == .enabled)
        #expect(fake.registerCount == 1)

        try fake.unregister()
        #expect(fake.status == .notRegistered)
        #expect(fake.unregisterCount == 1)
    }

    @Test func canReportAnUnknownStatus() {
        #expect(FakeLoginItemController(status: .unknown).status == .unknown)
    }

    @Test func canBeToldToFail() throws {
        let fake = FakeLoginItemController()
        fake.failNextRegister(with: .registrationFailed("denied"))
        #expect(throws: LoginItemError.registrationFailed("denied")) { try fake.register() }
        #expect(fake.status == .notRegistered, "a failed registration must not claim to be enabled")
        #expect(fake.registerCount == 1)
    }
}
