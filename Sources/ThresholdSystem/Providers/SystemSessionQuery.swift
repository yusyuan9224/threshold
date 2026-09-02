import CoreGraphics
import ThresholdDomain

/// Reads of `CGSessionCopyCurrentDictionary()`, split into a live query and a pure mapping.
///
/// ADR-004 confines the undocumented `CGSSessionScreenIsLocked` key to this target. Keeping the
/// mapping pure means the fail-closed rules are tested without a real device, and a future macOS
/// that changes the shape of the dictionary only needs this one file replaced.
enum SystemSessionQuery {
    /// The current session dictionary, or `nil` when the process has no window server session.
    static func dictionary() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }
}

/// Maps a session dictionary snapshot to `ScreenState`.
public enum ScreenStateMapping {
    /// Undocumented key, present only while the screen is locked (SPIKE-001, ADR-004).
    public static let lockedKey = "CGSSessionScreenIsLocked"

    /// - Parameter dictionary: a `CGSessionCopyCurrentDictionary()` snapshot, or `nil` when the
    ///   query itself failed.
    /// - Returns: `.unlocked` when the key is absent (SPIKE-001 measured absence, not zero, while
    ///   unlocked), `.locked` for a true/non-zero value, and `.unknown` whenever the dictionary is
    ///   unavailable or the value has an unrecognised shape.
    public static func screenState(fromSessionDictionary dictionary: [String: Any]?) -> ScreenState {
        guard let dictionary else { return .unknown }
        guard let value = dictionary[lockedKey] else { return .unlocked }
        guard let flag = truthValue(of: value) else { return .unknown }
        return flag ? .locked : .unlocked
    }

    /// Live query. Never throws and never blocks; safe from any thread.
    static func current() -> ScreenState {
        screenState(fromSessionDictionary: SystemSessionQuery.dictionary())
    }
}

/// Maps a session dictionary snapshot to `SessionState`.
public enum SessionStateMapping {
    /// `kCGSessionOnConsoleKey`: this session owns the console (it is not switched away or remote).
    public static let onConsoleKey = kCGSessionOnConsoleKey as String

    /// - Returns: `.unknown` when the dictionary is unavailable, the key is missing, or the value
    ///   has an unrecognised shape. A missing key is not evidence of an inactive session, and
    ///   `RequiredPreconditions` treats `.unknown` as a veto (security.md §2 rule 1).
    public static func sessionState(fromSessionDictionary dictionary: [String: Any]?) -> SessionState {
        guard let dictionary, let value = dictionary[onConsoleKey], let flag = truthValue(of: value) else {
            return .unknown
        }
        return flag ? .active : .inactive
    }

    /// Live query. Never throws and never blocks; safe from any thread.
    static func current() -> SessionState {
        sessionState(fromSessionDictionary: SystemSessionQuery.dictionary())
    }
}

/// Accepts both shapes the window server has been observed to use: a bridged `CFBoolean` and a
/// bridged `CFNumber`. Anything else is unrecognised rather than assumed false.
private func truthValue(of value: Any) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let number = value as? Int { return number != 0 }
    return nil
}
