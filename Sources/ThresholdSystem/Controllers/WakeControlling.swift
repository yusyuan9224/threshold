import IOKit.pwr_mgt
import os

/// Wakes the display when the user comes back.
///
/// Only meaningful while the Mac itself is awake and the display is asleep or the screen locked.
/// Once the Mac is fully asleep no supported mechanism lets a third-party app wake it on BLE
/// presence, and the product does not pretend otherwise (system-integration.md §4).
public protocol WakeControlling: Sendable {
    func wakeDisplay() async throws
}

public enum WakeError: Error, Equatable, Sendable {
    /// `IOPMAssertionDeclareUserActivity` returned a non-success `IOReturn`.
    case assertionFailed(Int32)
}

/// Production `WakeControlling`.
///
/// `IOPMAssertionDeclareUserActivity` with `kIOPMUserActiveLocal` is the public, unprivileged way to
/// tell power management that the local user is present, which lights the display. SPIKE-003
/// measured it lighting a sleeping display on a locked Mac three times out of three, in under
/// 150 ms each time, with no permission prompt, and the login window then staying up for about 33 s
/// without input. The spike is still PARTIAL because that is far short of the fifty runs the spec
/// asks for.
///
/// Nothing is released. Despite the name, this call does not hand back a held assertion: it
/// declares a moment of user activity and power management ages it out on its own. Releasing the id
/// would be meaningless, and holding one would keep the display awake, which is not what
/// "wake on return" means.
public final class MacOSWakeController: WakeControlling, Sendable {
    /// Shown in `pmset -g assertions`, so it names the app rather than the internal call site.
    private let reason: String

    public init(reason: String = "Threshold wake on return") {
        self.reason = reason
    }

    public func wakeDisplay() async throws {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &assertionID)
        guard result == kIOReturnSuccess else { throw WakeError.assertionFailed(result) }
    }
}

/// Test double for `WakeControlling` (docs/specs/testing.md §1, L3).
public final class SpyWakeController: WakeControlling, Sendable {
    private struct State: Sendable {
        var wakeCount = 0
        var failure: WakeError?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(failure: WakeError? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(failure: failure))
    }

    /// Counts every call, including calls that then failed.
    public var wakeCount: Int { state.withLock { $0.wakeCount } }

    public func fail(with error: WakeError) { state.withLock { $0.failure = error } }
    public func stopFailing() { state.withLock { $0.failure = nil } }

    public func wakeDisplay() async throws {
        let failure = state.withLock { state -> WakeError? in
            state.wakeCount += 1
            return state.failure
        }
        if let failure { throw failure }
    }
}
