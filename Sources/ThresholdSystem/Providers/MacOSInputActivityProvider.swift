import CoreGraphics
import ThresholdDomain

/// When a user-idle sample may be taken at all.
public enum InputActivityGate {
    /// - Returns: `true` only when the feature is enabled *and* this session demonstrably owns the
    ///   console with an unlocked screen.
    ///
    /// SPIKE-008 (2026-09-02, CONDITIONAL GO) measured that `.hidSystemState` matches real HID
    /// idleness exactly once the session is unlocked and active, resetting on every keystroke and
    /// mouse move, with no permission prompt. It also measured that a keystroke at the lock screen
    /// does *not* reset it, so while the screen is locked the counter keeps climbing and describes
    /// nothing the user did. The screen and session conditions are therefore the spike's condition,
    /// not caution: outside them the number is not about this user's presence at all.
    ///
    /// `inputIdle` is the only supporting evidence that authorises a silence-based lock
    /// (security.md §2 rule 3), so a reading that cannot be trusted must be `nil`, never a guess.
    public static func shouldSample(isEnabled: Bool, session: SessionState, screen: ScreenState) -> Bool {
        isEnabled && session == .active && screen == .unlocked
    }
}

/// Production `InputActivityProviding`.
///
/// Reads `.hidSystemState` rather than `.combinedSessionState`. SPIKE-008 measured the two tracking
/// each other identically on an unlocked console session, but `.combinedSessionState` is also reset
/// by `IOPMAssertionDeclareUserActivity` — the exact call `MacOSWakeController` makes — and by
/// keystrokes at the lock screen. Either would let the app's own wake, or a failed password attempt,
/// masquerade as evidence that the user is present.
///
/// Known gaps the spike left open, listed as conditions rather than hidden: the screen saver and
/// fast user switching were not measured, and neither was whether a synthetic `CGEvent` counts.
/// The last one is moot here — this codebase generates no synthetic events, and
/// scripts/check-boundaries.sh enforces that.
public final class MacOSInputActivityProvider: InputActivityProviding, Sendable {
    private let session: any SessionStateProviding
    private let screen: any ScreenStateProviding
    private let isEnabled: Bool

    /// - Parameter isEnabled: kept as a switch so a build, a test, or a support case can turn the
    ///   signal off without replacing the provider. Defaults to on: SPIKE-008 is a conditional go,
    ///   and the conditions are enforced by `InputActivityGate`.
    public init(session: any SessionStateProviding, screen: any ScreenStateProviding, isEnabled: Bool = true) {
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

    /// `kCGAnyInputEventType`, which `CGEventTypes.h` defines as `(CGEventType)(~0)`. `.null` counts
    /// only null events, which no user input produces: that mistake is what made the first
    /// SPIKE-008 run return a counter rising at exactly 1 s/s regardless of what the user did.
    ///
    /// Optional rather than force-unwrapped: if a future SDK stops accepting that raw value, the
    /// provider reports `nil` (unknown) instead of trapping or, worse, silently measuring the wrong
    /// event class and handing Policy a number that could authorise a lock.
    private static let anyInputEventType: CGEventType? = CGEventType(rawValue: ~0)
}
