import os
import ServiceManagement

/// Whether the app is registered to launch at login.
///
/// `unknown` exists for the same reason it does on every provider: a status macOS reports that this
/// version does not recognise must not be presented as "off".
public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    /// Registered, but the user has to approve it in System Settings > General > Login Items.
    case requiresApproval
    /// macOS cannot find the registered item, typically after the app was moved or replaced.
    case notFound
    case unknown
}

public enum LoginItemError: Error, Equatable, Sendable {
    case registrationFailed(String)
    case unregistrationFailed(String)
}

/// Launch-at-login, an optional permission asked for at the end of onboarding
/// (system-integration.md §6: request only when the feature requires it).
public protocol LoginItemControlling: Sendable {
    func register() throws
    func unregister() throws
    var status: LoginItemStatus { get }
}

/// Pure mapping, so the status table is covered without an installed app bundle.
public enum LoginItemStatusMapping {
    public static func status(for status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
}

/// Production `LoginItemControlling`, over `SMAppService.mainApp`.
///
/// This is the supported replacement for the deprecated `SMLoginItemSetEnabled` and needs no helper
/// bundle and no elevated privileges. It only works for a real app bundle: from a bare command-line
/// binary the status reads `.notFound`.
public final class SMAppServiceLoginItemController: LoginItemControlling, Sendable {
    public init() {}

    public var status: LoginItemStatus {
        LoginItemStatusMapping.status(for: SMAppService.mainApp.status)
    }

    public func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LoginItemError.registrationFailed(String(describing: error))
        }
    }

    public func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LoginItemError.unregistrationFailed(String(describing: error))
        }
    }
}

/// Test double for `LoginItemControlling`.
public final class FakeLoginItemController: LoginItemControlling, Sendable {
    private struct State: Sendable {
        var status: LoginItemStatus
        var registerCount = 0
        var unregisterCount = 0
        var registerFailure: LoginItemError?
        var unregisterFailure: LoginItemError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(status: LoginItemStatus = .notRegistered) {
        state = OSAllocatedUnfairLock(initialState: State(status: status))
    }

    public var status: LoginItemStatus { state.withLock { $0.status } }
    public var registerCount: Int { state.withLock { $0.registerCount } }
    public var unregisterCount: Int { state.withLock { $0.unregisterCount } }

    /// Makes the next `register()` throw, then clears itself.
    public func failNextRegister(with error: LoginItemError) {
        state.withLock { $0.registerFailure = error }
    }

    /// Makes the next `unregister()` throw, then clears itself.
    public func failNextUnregister(with error: LoginItemError) {
        state.withLock { $0.unregisterFailure = error }
    }

    public func register() throws {
        let failure = state.withLock { state -> LoginItemError? in
            state.registerCount += 1
            guard let failure = state.registerFailure else {
                state.status = .enabled
                return nil
            }
            state.registerFailure = nil
            return failure
        }
        if let failure { throw failure }
    }

    public func unregister() throws {
        let failure = state.withLock { state -> LoginItemError? in
            state.unregisterCount += 1
            guard let failure = state.unregisterFailure else {
                state.status = .notRegistered
                return nil
            }
            state.unregisterFailure = nil
            return failure
        }
        if let failure { throw failure }
    }
}
