import CoreGraphics
import ThresholdDomain

/// When a user-idle sample may be taken at all.
public enum InputActivityGate {
    /// - Returns: `true` only when the feature is explicitly enabled *and* this session
    ///   demonstrably owns the console with an unlocked screen.
    ///
    /// SPIKE-008 has not run, so the behaviour of `CGEventSource.secondsSinceLastEventType` on the
    /// lock screen and in a switched-away session is unverified. Sampling anyway would feed Policy a
    /// number that might describe another session's activity, and `inputIdle` is exactly the
    /// supporting evidence that authorises a silence-based lock (security.md §2 rule 3). Anything
    /// short of a confirmed unlocked console session therefore reports `nil`.
    public static func shouldSample(isEnabled: Bool, session: SessionState, screen: ScreenState) -> Bool {
        isEnabled && session == .active && screen == .unlocked
    }
}

/// Production `InputActivityProviding`.
///
/// Disabled by default. The Coordinator keeps feeding Policy `nil` until SPIKE-008 measures what the
/// idle counter does across lock, unlock and fast user switching
/// (docs/specs/system-integration.md §1).
public final class MacOSInputActivityProvider: InputActivityProviding, Sendable {
    private let session: any SessionStateProviding
    private let screen: any ScreenStateProviding
    private let isEnabled: Bool

    public init(session: any SessionStateProviding, screen: any ScreenStateProviding, isEnabled: Bool = false) {
        self.session = session
        self.screen = screen
        self.isEnabled = isEnabled
    }

    public var current: Duration? {
        guard InputActivityGate.shouldSample(isEnabled: isEnabled, session: session.current, screen: screen.current) else {
            return nil
        }
        guard let anyInputEventType = Self.anyInputEventType else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return .seconds(seconds)
    }

    /// `kCGAnyInputEventType`, which `CGEventTypes.h` defines as `(CGEventType)(~0)`. `.null` would
    /// count only null events, which is a different question; the any-event pseudo-type is the one
    /// that answers "how long since the user touched anything".
    ///
    /// Optional rather than force-unwrapped: if a future SDK stops accepting that raw value, the
    /// provider reports `nil` (unknown) instead of trapping or, worse, silently measuring the wrong
    /// event class and handing Policy a number that could authorise a lock.
    private static let anyInputEventType: CGEventType? = CGEventType(rawValue: ~0)
}
