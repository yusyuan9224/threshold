import ThresholdDomain

/// A trusted device and the name the *user* gave it.
///
/// The name is always user-supplied: model-name lookup would mean reading the
/// system Bluetooth database, which ADR-004 and ADR-009 forbid.
public struct RegisteredDevice: Codable, Sendable, Equatable, Hashable {
    public let id: DeviceID
    public let name: String

    public init(id: DeviceID, name: String) {
        self.id = id
        self.name = name
    }
}

/// In-memory `DeviceID` ↔ user-given-name mapping (bluetooth.md §4).
///
/// A plain value type: persistence belongs to `ThresholdSystem`'s `DeviceStore`,
/// so this type only has to be `Codable` and round-trip losslessly. Order is
/// preserved because it is the order the user sees in the device list.
///
/// Mutation returns a new value rather than editing in place, so a registry handed
/// to the Coordinator can never change underneath it.
public struct DeviceRegistry: Codable, Sendable, Equatable {
    public private(set) var devices: [RegisteredDevice]

    public init(devices: [RegisteredDevice] = []) {
        self.devices = devices
    }

    /// The set handed to `BLEScanning.startScanning(for:)`.
    public var deviceIDs: Set<DeviceID> { Set(devices.map(\.id)) }

    public var isEmpty: Bool { devices.isEmpty }

    public func contains(_ id: DeviceID) -> Bool { devices.contains { $0.id == id } }

    public func name(for id: DeviceID) -> String? {
        devices.first { $0.id == id }?.name
    }

    /// Adds a device, or renames it in place if the id is already registered.
    /// Position is preserved so the user's list does not reorder itself.
    public func adding(_ device: RegisteredDevice) -> DeviceRegistry {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else {
            return DeviceRegistry(devices: devices + [device])
        }
        var updated = devices
        updated[index] = device
        return DeviceRegistry(devices: updated)
    }

    public func adding(id: DeviceID, name: String) -> DeviceRegistry {
        adding(RegisteredDevice(id: id, name: name))
    }

    /// Removing an unknown id is a no-op, not an error: the caller's intent
    /// ("this device must not be trusted") already holds.
    public func removing(_ id: DeviceID) -> DeviceRegistry {
        DeviceRegistry(devices: devices.filter { $0.id != id })
    }

    /// Renaming an unknown id is a no-op — it must never silently register a device.
    public func renaming(_ id: DeviceID, to name: String) -> DeviceRegistry {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return self }
        var updated = devices
        updated[index] = RegisteredDevice(id: id, name: name)
        return DeviceRegistry(devices: updated)
    }
}
