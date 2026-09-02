import Foundation
import os
import ThresholdDomain

/// On-disk shape of `PolicySettings`.
///
/// `PolicySettings` is `Codable` (proximity-domain.md §6.1), but its synthesized keys are the
/// Domain's property names. Persisting it directly would freeze those names into a file format and
/// turn every Domain rename into a migration. This record is the on-disk schema, versioned by
/// `JSONFileStore`, and maps every `PolicySettings` field explicitly — `JSONFileSettingsStoreTests.everyFieldSurvivesARoundTrip`
/// round-trips a fully non-default `PolicySettings` so a field added to the Domain type without a
/// mapping here fails a test rather than silently loading as its default.
///
/// Durations are stored as whole milliseconds, which is finer than any setting the UI exposes.
struct SettingsRecord: Codable, Sendable, Equatable {
    var autoLock: Bool
    var wakeOnReturn: Bool
    var lockOnDepartureThenSilent: Bool
    /// `nil` means `SilenceLockPolicy.never`, which is not the same as a zero timeout.
    var silenceLockTimeoutMilliseconds: Int64?
    var departedIdleGuardMilliseconds: Int64
    var silenceIdleGuardMilliseconds: Int64
    var wakeWindowMilliseconds: Int64
    var retryAfterMilliseconds: Int64
    var maxAttempts: Int

    init(_ settings: PolicySettings) {
        autoLock = settings.autoLock
        wakeOnReturn = settings.wakeOnReturn
        lockOnDepartureThenSilent = settings.lockOnDepartureThenSilent
        switch settings.silenceLock {
        case .never: silenceLockTimeoutMilliseconds = nil
        case .afterTimeout(let timeout): silenceLockTimeoutMilliseconds = timeout.wholeMilliseconds
        }
        departedIdleGuardMilliseconds = settings.departedIdleGuard.wholeMilliseconds
        silenceIdleGuardMilliseconds = settings.silenceIdleGuard.wholeMilliseconds
        wakeWindowMilliseconds = settings.wakeWindow.wholeMilliseconds
        retryAfterMilliseconds = settings.retryAfter.wholeMilliseconds
        maxAttempts = settings.maxAttempts
    }

    var settings: PolicySettings {
        var settings = PolicySettings()
        settings.autoLock = autoLock
        settings.wakeOnReturn = wakeOnReturn
        settings.lockOnDepartureThenSilent = lockOnDepartureThenSilent
        settings.silenceLock = silenceLockTimeoutMilliseconds.map { .afterTimeout(.milliseconds($0)) } ?? .never
        settings.departedIdleGuard = .milliseconds(departedIdleGuardMilliseconds)
        settings.silenceIdleGuard = .milliseconds(silenceIdleGuardMilliseconds)
        settings.wakeWindow = .milliseconds(wakeWindowMilliseconds)
        settings.retryAfter = .milliseconds(retryAfterMilliseconds)
        settings.maxAttempts = maxAttempts
        return settings
    }
}

extension Duration {
    /// Whole milliseconds, truncating anything finer.
    var wholeMilliseconds: Int64 { wholeNanoseconds / 1_000_000 }
}

public protocol SettingsStore: Sendable {
    /// - Returns: `nil` when the user has never changed a setting, so the caller applies its own
    ///   defaults rather than inheriting whatever this build happens to encode.
    func load() throws -> PolicySettings?
    func save(_ settings: PolicySettings) throws
}

/// Production `SettingsStore`.
///
/// A JSON file rather than `UserDefaults`: the same versioned envelope, the same explicit decode
/// failure, and one place to look when a user reports settings that did not stick.
public struct JSONFileSettingsStore: SettingsStore {
    private let file: JSONFileStore<SettingsRecord>

    public init(directory: URL, fileName: String = "settings.json") {
        file = JSONFileStore(url: directory.appendingPathComponent(fileName, isDirectory: false))
    }

    public func load() throws -> PolicySettings? { try file.load()?.settings }
    public func save(_ settings: PolicySettings) throws { try file.save(SettingsRecord(settings)) }
}

/// Test double for `SettingsStore`.
public final class InMemorySettingsStore: SettingsStore, Sendable {
    private struct State: Sendable {
        var settings: PolicySettings?
        var saveCount = 0
        var loadFailure: StoreError?
        var saveFailure: StoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(settings: PolicySettings? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(settings: settings))
    }

    public var saveCount: Int { state.withLock { $0.saveCount } }

    public func failLoad(with error: StoreError?) { state.withLock { $0.loadFailure = error } }
    public func failSave(with error: StoreError?) { state.withLock { $0.saveFailure = error } }

    public func load() throws -> PolicySettings? {
        try state.withLock { state in
            if let failure = state.loadFailure { throw failure }
            return state.settings
        }
    }

    public func save(_ settings: PolicySettings) throws {
        try state.withLock { state in
            if let failure = state.saveFailure { throw failure }
            state.settings = settings
            state.saveCount += 1
        }
    }
}
