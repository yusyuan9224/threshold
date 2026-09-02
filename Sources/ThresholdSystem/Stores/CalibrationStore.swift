import Foundation
import os
import ThresholdDomain

public protocol CalibrationStore: Sendable {
    /// - Returns: an empty list when nothing has been saved yet.
    func load() throws -> [CalibrationRecord]
    func save(_ records: [CalibrationRecord]) throws
}

/// Production `CalibrationStore`.
///
/// `CalibrationRecord` deliberately holds no `MonotonicInstant`: monotonic time is meaningless
/// across process boundaries, which is exactly what persistence crosses.
public struct JSONFileCalibrationStore: CalibrationStore {
    private let file: JSONFileStore<[CalibrationRecord]>

    public init(directory: URL, fileName: String = "calibration.json") {
        file = JSONFileStore(url: directory.appendingPathComponent(fileName, isDirectory: false))
    }

    public func load() throws -> [CalibrationRecord] { try file.load() ?? [] }
    public func save(_ records: [CalibrationRecord]) throws { try file.save(records) }
}

/// Test double for `CalibrationStore`.
public final class InMemoryCalibrationStore: CalibrationStore, Sendable {
    private struct State: Sendable {
        var records: [CalibrationRecord]
        var saveCount = 0
        var loadFailure: StoreError?
        var saveFailure: StoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(records: [CalibrationRecord] = []) {
        state = OSAllocatedUnfairLock(initialState: State(records: records))
    }

    public var saveCount: Int { state.withLock { $0.saveCount } }

    public func failLoad(with error: StoreError?) { state.withLock { $0.loadFailure = error } }
    public func failSave(with error: StoreError?) { state.withLock { $0.saveFailure = error } }

    public func load() throws -> [CalibrationRecord] {
        try state.withLock { state in
            if let failure = state.loadFailure { throw failure }
            return state.records
        }
    }

    public func save(_ records: [CalibrationRecord]) throws {
        try state.withLock { state in
            if let failure = state.saveFailure { throw failure }
            state.records = records
            state.saveCount += 1
        }
    }
}
