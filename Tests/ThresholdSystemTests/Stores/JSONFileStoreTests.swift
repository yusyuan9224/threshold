import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdSystem

/// Runs `body` against a fresh directory and removes it afterwards. Every store test writes to a
/// temporary directory: the production location depends on the bundle identifier, which a test
/// binary does not have.
private func withTemporaryDirectory(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (URL) throws -> Void
) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("threshold-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("could not clean up \(url.lastPathComponent): \(error)", sourceLocation: sourceLocation)
        }
    }
    try body(url)
}

private let deviceA = DeviceRecord(device: DeviceID("device-A"), name: "Phone")
private let deviceB = DeviceRecord(device: DeviceID("device-B"), name: "Watch")

private func calibrationRecord(device: String) -> CalibrationRecord {
    CalibrationRecord(
        device: DeviceID(device),
        macIdentity: "mac-1",
        profile: CalibrationProfile(nearBaseline: -52, farBaseline: -84, noise: 3.5, midpoint: -68, slope: 5.5),
        osMajorVersion: 26,
        appVersion: "0.1.0",
        createdAtUnixSeconds: 1_756_771_200
    )
}

@Suite struct JSONFileDeviceStoreTests {
    @Test func absentFileReadsAsNoDevices() throws {
        try withTemporaryDirectory { directory in
            let devices = try JSONFileDeviceStore(directory: directory).load()
            #expect(devices.isEmpty)
        }
    }

    @Test func savedDevicesComeBackUnchanged() throws {
        try withTemporaryDirectory { directory in
            let store = JSONFileDeviceStore(directory: directory)
            try store.save([deviceA, deviceB])
            #expect(try store.load() == [deviceA, deviceB])
        }
    }

    @Test func savingAgainReplacesTheWholeList() throws {
        try withTemporaryDirectory { directory in
            let store = JSONFileDeviceStore(directory: directory)
            try store.save([deviceA, deviceB])
            try store.save([deviceB])
            #expect(try store.load() == [deviceB])
        }
    }

    @Test func createsAMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let nested = directory.appendingPathComponent("Threshold", isDirectory: true)
            let store = JSONFileDeviceStore(directory: nested)
            try store.save([deviceA])
            #expect(try store.load() == [deviceA])
        }
    }

    @Test func unreadableContentThrowsAndNeverResetsSilently() throws {
        try withTemporaryDirectory { directory in
            let store = JSONFileDeviceStore(directory: directory)
            try store.save([deviceA])
            try Data("this is not json".utf8).write(to: directory.appendingPathComponent("devices.json"))

            #expect(throws: StoreError.self) { try store.load() }
        }
    }

    @Test func anUnknownSchemaVersionThrowsRatherThanBeingGuessedAt() throws {
        try withTemporaryDirectory { directory in
            let document = #"{"schemaVersion":99,"body":[]}"#
            try Data(document.utf8).write(to: directory.appendingPathComponent("devices.json"))

            let store = JSONFileDeviceStore(directory: directory)
            do {
                _ = try store.load()
                Issue.record("expected an unsupported-schema error")
            } catch let error as StoreError {
                guard case .unsupportedSchemaVersion(_, let found, let supported) = error else {
                    Issue.record("expected .unsupportedSchemaVersion, got \(error)")
                    return
                }
                #expect(found == 99)
                #expect(supported == 1)
            }
        }
    }

    @Test func errorsNameTheFileAndNotTheUsersHomeDirectory() throws {
        try withTemporaryDirectory { directory in
            try Data("nope".utf8).write(to: directory.appendingPathComponent("devices.json"))
            do {
                _ = try JSONFileDeviceStore(directory: directory).load()
                Issue.record("expected a decode error")
            } catch let error as StoreError {
                #expect("\(error)".contains("devices.json"))
                #expect("\(error)".contains(directory.path) == false)
            }
        }
    }
}

@Suite struct JSONFileCalibrationStoreTests {
    @Test func absentFileReadsAsNoRecords() throws {
        try withTemporaryDirectory { directory in
            let records = try JSONFileCalibrationStore(directory: directory).load()
            #expect(records.isEmpty)
        }
    }

    @Test func savedRecordsComeBackUnchanged() throws {
        try withTemporaryDirectory { directory in
            let store = JSONFileCalibrationStore(directory: directory)
            let records = [calibrationRecord(device: "device-A"), calibrationRecord(device: "device-B")]
            try store.save(records)
            #expect(try store.load() == records)
        }
    }

    @Test func unreadableContentThrows() throws {
        try withTemporaryDirectory { directory in
            try Data("{".utf8).write(to: directory.appendingPathComponent("calibration.json"))
            #expect(throws: StoreError.self) { try JSONFileCalibrationStore(directory: directory).load() }
        }
    }
}

@Suite struct JSONFileSettingsStoreTests {
    @Test func absentFileReadsAsNoSavedSettings() throws {
        try withTemporaryDirectory { directory in
            let settings = try JSONFileSettingsStore(directory: directory).load()
            #expect(settings == nil)
        }
    }

    @Test func everyFieldSurvivesARoundTrip() throws {
        try withTemporaryDirectory { directory in
            var settings = PolicySettings()
            settings.autoLock = false
            settings.wakeOnReturn = false
            settings.lockOnDepartureThenSilent = false
            settings.silenceLock = .afterTimeout(.seconds(240))
            settings.departedIdleGuard = .seconds(11)
            settings.silenceIdleGuard = .seconds(77)
            settings.wakeWindow = .seconds(21)
            settings.retryAfter = .milliseconds(2_500)
            settings.maxAttempts = 5

            let store = JSONFileSettingsStore(directory: directory)
            try store.save(settings)
            #expect(try store.load() == settings)
        }
    }

    @Test func defaultsSurviveARoundTrip() throws {
        try withTemporaryDirectory { directory in
            let store = JSONFileSettingsStore(directory: directory)
            try store.save(PolicySettings())
            #expect(try store.load() == PolicySettings())
        }
    }

    @Test func neverSilenceLockIsDistinctFromAZeroTimeout() throws {
        try withTemporaryDirectory { directory in
            var settings = PolicySettings()
            settings.silenceLock = .never
            let store = JSONFileSettingsStore(directory: directory)
            try store.save(settings)
            #expect(try store.load()?.silenceLock == .never)

            settings.silenceLock = .afterTimeout(.zero)
            try store.save(settings)
            #expect(try store.load()?.silenceLock == .afterTimeout(.zero))
        }
    }

    @Test func unreadableContentThrows() throws {
        try withTemporaryDirectory { directory in
            try Data("[]".utf8).write(to: directory.appendingPathComponent("settings.json"))
            #expect(throws: StoreError.self) { try JSONFileSettingsStore(directory: directory).load() }
        }
    }
}
