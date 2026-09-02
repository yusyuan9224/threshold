import AppKit
import Foundation

/// The `NSWorkspace` notification surface the providers use, read once here so that the rest of the
/// target never touches `NSWorkspace.shared` directly.
///
/// `NSWorkspace.shared` and its notification names are documented, thread-safe globals; naming them
/// in one place keeps the AppKit dependency to a single file.
enum NSWorkspaceNotifications {
    static var center: NotificationCenter { NSWorkspace.shared.notificationCenter }

    static let willSleep = NSWorkspace.willSleepNotification
    static let didWake = NSWorkspace.didWakeNotification
    static let screensDidSleep = NSWorkspace.screensDidSleepNotification
    static let screensDidWake = NSWorkspace.screensDidWakeNotification
    static let sessionDidBecomeActive = NSWorkspace.sessionDidBecomeActiveNotification
    static let sessionDidResignActive = NSWorkspace.sessionDidResignActiveNotification
}
