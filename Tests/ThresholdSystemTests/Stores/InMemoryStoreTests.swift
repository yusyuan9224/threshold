import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdSystem

@Suite struct InMemoryStoreTests {
    @Test func deviceStoreRoundTripsAndCountsSaves() throws {
        let store = InMemoryDeviceStore()
        #expect(try store.load().isEmpty)

        let record = DeviceRecord(device: DeviceID("device-A"), name: "Phone")
        try store.save([record])
        #expect(try store.load() == [record])
        #expect(store.saveCount == 1)
    }

    @Test func deviceStoreCanBeToldToFail() throws {
        let store = InMemoryDeviceStore()
        store.failLoad(with: .readFailed(file: "devices.json", message: "disk gone"))
        #expect(throws: StoreError.readFailed(file: "devices.json", message: "disk gone")) { try store.load() }
    }

    @Test func calibrationStoreRoundTrips() throws {
        let record = CalibrationRecord(
            device: DeviceID("device-A"),
            macIdentity: "mac-1",
            profile: .default,
            osMajorVersion: 26,
            appVersion: "0.1.0",
            createdAtUnixSeconds: 1_756_771_200
        )
        let store = InMemoryCalibrationStore(records: [record])
        #expect(try store.load() == [record])

        try store.save([])
        #expect(try store.load().isEmpty)
    }

    @Test func settingsStoreStartsEmpty() throws {
        let store = InMemorySettingsStore()
        #expect(try store.load() == nil)

        var settings = PolicySettings()
        settings.autoLock = false
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    @Test func settingsStoreCanBeToldToFailOnSave() throws {
        let store = InMemorySettingsStore()
        store.failSave(with: .writeFailed(file: "settings.json", message: "read-only volume"))
        #expect(throws: StoreError.writeFailed(file: "settings.json", message: "read-only volume")) {
            try store.save(PolicySettings())
        }
        #expect(try store.load() == nil, "a failed save must not be visible to a later load")
    }
}

@Suite struct MacIdentityTests {
    @Test func reportsTheHardwareUUIDOrNothing() {
        // The IO registry always carries `IOPlatformUUID` on real hardware, but the contract this
        // codebase depends on is only that an unavailable identity is `nil` and never an empty or
        // placeholder string: `CalibrationRecord.macIdentity` gates automation (security.md §2 rule 4).
        guard let identity = MacIdentity.current() else { return }
        #expect(identity.isEmpty == false)
        #expect(identity.trimmingCharacters(in: .whitespaces) == identity)
    }

    @Test func isStableWithinAProcess() {
        #expect(MacIdentity.current() == MacIdentity.current())
    }
}

@Suite struct ApplicationSupportDirectoryTests {
    @Test func namesASubdirectoryOfApplicationSupport() throws {
        let url = try ApplicationSupportDirectory.url(bundleIdentifier: "com.example.Threshold")
        #expect(url.lastPathComponent == "com.example.Threshold")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func rejectsAnIdentifierThatWouldEscapeTheDirectory() {
        #expect(throws: StoreError.self) {
            try ApplicationSupportDirectory.url(bundleIdentifier: "../../etc")
        }
    }
}
