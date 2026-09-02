import AppKit
import SwiftUI
import ThresholdAppKit
import ThresholdDomain

/// The menu-bar popover: status, what the app currently believes, the two switches, and the
/// way into everything else.
///
/// It is deliberately a *report* first and a control panel second. The top three lines answer
/// "am I protected, what do you think is happening, and on the strength of what evidence" —
/// which is the question a security tool driven by an inference has to be able to answer at a
/// glance (ADR-007, ADR-008).
struct MenuContentView: View {
    let container: AppContainer
    @Environment(\.openWindow) private var openWindow

    private var model: AppModel { container.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if let banner = model.degradedBanner {
                DegradedBanner(message: banner, remedy: model.bluetoothRemedy)
            }

            if !model.startupIssues.isEmpty {
                startupIssues
            }

            Divider()
            beliefSection
            Divider()
            switches
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var statusHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(PlainLanguage.protectionStatus(model.protectionStatus))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.protectionStatus {
        case .active: return .green
        case .paused: return .orange
        case .notArmed: return .yellow
        case .initializing: return .secondary
        }
    }

    private var startupIssues: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.startupIssues, id: \.self) { issue in
                Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var beliefSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.presenceDescription)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.evidenceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DetailRow(title: "Trusted device") {
                Text(model.trustedDeviceName ?? "None yet")
                    .fontWeight(.medium)
            }
            .font(.caption)
        }
    }

    /// The two switches map one-to-one onto `PolicySettings`, and each write goes through the
    /// container so it is persisted immediately rather than at quit — an app that forgets a
    /// security setting because it was force-quit is worse than one that writes eagerly.
    private var switches: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Lock when I leave", isOn: Binding(
                get: { model.settings.autoLock },
                set: { container.setAutoLock($0) }
            ))
            Toggle("Wake the display when I return", isOn: Binding(
                get: { model.settings.wakeOnReturn },
                set: { container.setWakeOnReturn($0) }
            ))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Set up device…") {
                container.presentOnboarding()
                open(WindowID.onboarding)
            }
            Button("Calibrate…") {
                container.presentCalibrationOnboarding()
                open(WindowID.onboarding)
            }
            .disabled(!model.hasTrustedDevice)
            Button("Settings…") { open(WindowID.settings) }
            DiagnosticsExportButton(container: container)
            Divider().padding(.vertical, 4)
            Button("Quit Threshold") {
                container.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    /// Menu-bar apps are `.accessory`, so a newly opened window appears behind whatever the
    /// user was doing unless the app is activated first.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
