import Foundation
import Testing
import ThresholdDomain
@testable import ThresholdBluetooth

@Suite struct DeviceRegistryTests {

    @Test func emptyRegistryHasNoDevices() {
        let registry = DeviceRegistry()
        #expect(registry.isEmpty)
        #expect(registry.deviceIDs.isEmpty)
        #expect(!registry.contains(deviceA))
        #expect(registry.name(for: deviceA) == nil)
    }

    @Test func addingRegistersTheDeviceUnderItsUserGivenName() {
        let registry = DeviceRegistry().adding(id: deviceA, name: "My iPhone")
        #expect(registry.contains(deviceA))
        #expect(registry.name(for: deviceA) == "My iPhone")
        #expect(registry.deviceIDs == [deviceA])
    }

    /// Mutation is by value: the original must be untouched.
    @Test func addingDoesNotMutateTheOriginal() {
        let original = DeviceRegistry()
        _ = original.adding(id: deviceA, name: "My iPhone")
        #expect(original.isEmpty)
    }

    @Test func addingAnExistingIDRenamesItInPlace() {
        let registry = DeviceRegistry()
            .adding(id: deviceA, name: "Phone")
            .adding(id: deviceB, name: "Watch")
            .adding(id: deviceA, name: "Work Phone")

        #expect(registry.devices.count == 2)
        #expect(registry.name(for: deviceA) == "Work Phone")
        // Position preserved, so the user's list does not reorder itself.
        #expect(registry.devices.map(\.id) == [deviceA, deviceB])
    }

    @Test func removingDropsOnlyTheNamedDevice() {
        let registry = DeviceRegistry()
            .adding(id: deviceA, name: "Phone")
            .adding(id: deviceB, name: "Watch")
            .removing(deviceA)

        #expect(!registry.contains(deviceA))
        #expect(registry.contains(deviceB))
        #expect(registry.deviceIDs == [deviceB])
    }

    @Test func removingAnUnknownDeviceIsANoOp() {
        let registry = DeviceRegistry().adding(id: deviceA, name: "Phone")
        #expect(registry.removing(deviceB) == registry)
    }

    @Test func renamingChangesOnlyTheName() {
        let registry = DeviceRegistry()
            .adding(id: deviceA, name: "Phone")
            .renaming(deviceA, to: "Personal iPhone")

        #expect(registry.name(for: deviceA) == "Personal iPhone")
        #expect(registry.deviceIDs == [deviceA])
    }

    /// Renaming must never quietly create trust for an unregistered device.
    @Test func renamingAnUnknownDeviceDoesNotRegisterIt() {
        let registry = DeviceRegistry().adding(id: deviceA, name: "Phone")
        let renamed = registry.renaming(deviceB, to: "Sneaky")
        #expect(renamed == registry)
        #expect(!renamed.contains(deviceB))
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let registry = DeviceRegistry()
            .adding(id: deviceA, name: "My iPhone")
            .adding(id: deviceB, name: "Apple Watch")

        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(DeviceRegistry.self, from: data)

        #expect(decoded == registry)
        #expect(decoded.devices.map(\.id) == [deviceA, deviceB])
        #expect(decoded.name(for: deviceB) == "Apple Watch")
    }

    @Test func emptyRegistryRoundTrips() throws {
        let data = try JSONEncoder().encode(DeviceRegistry())
        let decoded = try JSONDecoder().decode(DeviceRegistry.self, from: data)
        #expect(decoded == DeviceRegistry())
    }

    @Test func registeredDeviceRoundTrips() throws {
        let device = RegisteredDevice(id: deviceA, name: "My iPhone")
        let data = try JSONEncoder().encode(device)
        #expect(try JSONDecoder().decode(RegisteredDevice.self, from: data) == device)
    }
}
