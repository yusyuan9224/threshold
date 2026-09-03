import AppKit
import SwiftUI
import ThresholdAppKit

/// Window identifiers, in one place so `openWindow(id:)` and the `Window` scenes cannot drift.
enum WindowID {
    static let onboarding = "threshold.onboarding"
    static let settings = "threshold.settings"
}

/// Minimal delegate: activation policy and an orderly shutdown.
///
/// `LSUIElement` in the bundle's `Info.plist` already makes this a menu-bar-only app, but a
/// binary run straight out of `.build` has no `Info.plist` at all and would otherwise take a
/// Dock icon and a menu bar. Setting the policy here makes both paths behave the same, and it
/// is idempotent when the plist already said so.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `ThresholdApp.init`. A static rather than an injected property because
    /// `NSApplicationDelegateAdaptor` constructs the delegate itself, so there is no
    /// initialiser to pass the container through.
    static var container: AppContainer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Stops the Coordinator, then the scanner, before the process goes away.
    ///
    /// `.terminateLater` rather than doing this in `applicationWillTerminate`: the shutdown is
    /// asynchronous — the Coordinator is an actor — and the order it happens in is required
    /// (architecture.md §3: `coordinator.stop()` then `scanner.stopScanning()`, so a live actor
    /// cannot re-arm a scanner that has just been told to stop). Kicking off a detached task
    /// from a synchronous `applicationWillTerminate` would let the process exit part-way
    /// through that sequence. This is the one AppKit hook that can hold termination open until
    /// it has finished.
    ///
    /// Controller work already in flight is left alone: a lock that has been issued should
    /// finish (architecture.md §5.4).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let container = Self.container else { return .terminateNow }
        Self.container = nil
        Task {
            await container.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ThresholdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var container: AppContainer

    init() {
        let container = AppContainer.bootstrap()
        container.start()
        AppDelegate.container = container
        _container = State(initialValue: container)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(container: container)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel(PlainLanguage.protectionStatus(container.model.protectionStatus))
        }
        .menuBarExtraStyle(.window)

        Window("Set Up Threshold", id: WindowID.onboarding) {
            OnboardingWindow(container: container)
        }
        .windowResizability(.contentSize)

        Window("Threshold Settings", id: WindowID.settings) {
            SettingsWindow(container: container)
        }
        .windowResizability(.contentSize)
    }

    /// The icon carries the same four states as the status line, so a glance at the menu bar
    /// answers "am I protected right now?" without opening anything.
    private var menuBarSymbol: String {
        switch container.model.protectionStatus {
        case .active: return "lock.shield.fill"
        case .paused: return "exclamationmark.shield.fill"
        case .notArmed: return "shield.slash"
        case .initializing: return "shield"
        }
    }
}
