import AppKit
import SwiftUI
import ThresholdAppKit

/// The banner `security.md` §2 rule 2 requires: when the sensor is not healthy the app must
/// say, in the interface, that automatic protection is paused.
///
/// It is a banner rather than a subtle grey line on purpose. The failure mode this product
/// exists to avoid is a user who believes their Mac locks itself when it no longer can, so a
/// paused state has to be the loudest thing on the screen.
struct DegradedBanner: View {
    let message: String
    let remedy: BluetoothRemedy?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let remedy {
                    Button(remedyTitle(remedy)) { SystemSettingsLink.open(remedy) }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func remedyTitle(_ remedy: BluetoothRemedy) -> String {
        switch remedy {
        case .openPrivacySettings: return "Open Privacy & Security settings…"
        case .openBluetoothSettings: return "Open Bluetooth settings…"
        }
    }
}

/// Deep links into System Settings.
///
/// `x-apple.systempreferences:` is the documented URL scheme for this and needs no
/// entitlement. If the pane identifier ever stops resolving, `NSWorkspace` simply does
/// nothing — the app never assumes the user arrived somewhere.
enum SystemSettingsLink {
    static func open(_ remedy: BluetoothRemedy) {
        let target: String
        switch remedy {
        case .openPrivacySettings:
            target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .openBluetoothSettings:
            target = "x-apple.systempreferences:com.apple.BluetoothSettings"
        }
        guard let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openLoginItems() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Four bars, filled according to `DiscoveryRow.signalBars`.
///
/// Display only. Nothing in the presence pipeline reads these thresholds — presence is scored
/// against the calibrated profile — so the bars are a rough "is this thing near me?" hint for
/// picking the right row out of a long list.
struct SignalBars: View {
    let filled: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= filled ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + bar * 3))
            }
        }
        .accessibilityLabel("Signal strength \(filled) of 4")
    }
}

/// A label/value row used across the menu and the settings window.
struct DetailRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            content
        }
    }
}

extension Duration {
    /// Whole seconds, for progress labels.
    var displaySeconds: Int { Int(components.seconds) }
}
