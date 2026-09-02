import Foundation
import os
import ThresholdDomain

/// A trusted device as this target persists it.
///
/// `DeviceRegistry` lives in `ThresholdBluetooth`, which `ThresholdSystem` must not depend on
/// (architecture.md §2.2). So the store persists the identity and the user-chosen name, and the
/// composition root rebuilds the registry from that. The name is user-supplied on purpose: reading
/// the system Bluetooth database is prohibited (security.md §3).
public struct DeviceRecord: Codable, Sendable, Equatable {
    public let device: DeviceID
    public let name: String

    public init(device: DeviceID, name: String) {
        self.device = device
        self.name = name
    }
}

public protocol DeviceStore: Sendable {
    /// - Returns: an empty list when nothing has been saved yet.
    func load() throws -> [DeviceRecord]
    func save(_ records: [DeviceRecord]) throws
}

/// Production `DeviceStore`: one JSON file in the app's Application Support directory.
public struct JSONFileDeviceStore: DeviceStore {
    private let file: JSONFileStore<[DeviceRecord]>

    public init(directory: URL, fileName: String = "devices.json") {
        file = JSONFileStore(url: directory.appendingPathComponent(fileName, isDirectory: false))
    }

    public func load() throws -> [DeviceRecord] { try file.load() ?? [] }
    public func save(_ records: [DeviceRecord]) throws { try file.save(records) }
}

/// Test double for `DeviceStore`.
public final class InMemoryDeviceStore: DeviceStore, Sendable {
    private struct State: Sendable {
        var records: [DeviceRecord]
        var saveCount = 0
        var loadFailure: StoreError?
        var saveFailure: StoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(records: [DeviceRecord] = []) {
        state = OSAllocatedUnfairLock(initialState: State(records: records))
    }

    public var saveCount: Int { state.withLock { $0.saveCount } }

    public func failLoad(with error: StoreError?) { state.withLock { $0.loadFailure = error } }
    public func failSave(with error: StoreError?) { state.withLock { $0.saveFailure = error } }

    public func load() throws -> [DeviceRecord] {
        try state.withLock { state in
            if let failure = state.loadFailure { throw failure }
            return state.records
        }
    }

    public func save(_ records: [DeviceRecord]) throws {
        try state.withLock { state in
            if let failure = state.saveFailure { throw failure }
            state.records = records
            state.saveCount += 1
        }
    }
}
