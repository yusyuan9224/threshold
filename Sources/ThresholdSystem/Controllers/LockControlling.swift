import os
import ThresholdDomain

/// Locks the screen.
///
/// Locking is the one system action the main line is allowed to take unattended, and it only ever
/// moves security in the safe direction (security.md §1.1). It is deliberately *not* paired with an
/// unlock: authentication stays with macOS.
public protocol LockControlling: Sendable {
    /// Requests a lock and returns only once the screen has been observed locked.
    ///
    /// - Throws: `LockError.notConfirmed` when the screen did not lock in time. The caller does not
    ///   retry: the Policy ledger owns retry and give-up (architecture.md §6).
    func lock(reason: LockReason) async throws
}

public enum LockError: Error, Equatable, Sendable {
    /// Every configured strategy refused. The payload names each one and why, for diagnostics only.
    case allStrategiesFailed([String])
    /// The lock was requested but `ScreenStateProviding` never reported `.locked` in time. An
    /// `.unknown` screen state is not a confirmation.
    case notConfirmed
}

/// One way of asking macOS to lock the screen.
///
/// Kept as a protocol because SPIKE-007 has only sampled path ①. When it finishes, further
/// strategies drop in behind the existing ones without changing the controller.
///
/// Path ② (synthesising ⌃⌘Q with `CGEvent`) is permanently excluded from this codebase: it needs
/// Accessibility, which the main line refuses to request, and keystroke synthesis is a prohibited
/// behaviour (security.md §3, enforced by scripts/check-boundaries.sh).
public protocol LockStrategy: Sendable {
    /// Stable identifier for diagnostics. Never contains user data.
    var name: String { get }

    /// Asks macOS to lock. Returning successfully means the request was accepted, not that the
    /// screen is locked; the controller confirms that separately.
    func requestLock() async throws
}

public enum LockStrategyError: Error, Equatable, Sendable {
    /// The mechanism does not exist on this machine.
    case unavailable(String)
    /// The mechanism exists but refused the request.
    case failed(String)
}

/// Test double for `LockControlling` (docs/specs/testing.md §1, L3).
public final class SpyLockController: LockControlling, Sendable {
    private struct State: Sendable {
        var reasons: [LockReason] = []
        var failure: LockError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(failure: LockError? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(failure: failure))
    }

    /// Every reason passed to `lock`, in call order, including calls that then failed.
    public var reasons: [LockReason] { state.withLock { $0.reasons } }
    public var lockCount: Int { state.withLock { $0.reasons.count } }

    public func fail(with error: LockError) { state.withLock { $0.failure = error } }
    public func stopFailing() { state.withLock { $0.failure = nil } }

    public func lock(reason: LockReason) async throws {
        let failure = state.withLock { state -> LockError? in
            state.reasons.append(reason)
            return state.failure
        }
        if let failure { throw failure }
    }
}
