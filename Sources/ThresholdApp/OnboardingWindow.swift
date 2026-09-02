import AppKit
import SwiftUI
import ThresholdAppKit
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// First-launch setup: Bluetooth → pick a device → calibrate → login item.
///
/// Every step's state lives in `OnboardingFlow`; this file only draws it. That is why the
/// ordering rules (Bluetooth explained before the prompt, login item last, calibration
/// skippable) are asserted in tests rather than trusted to a view.
struct OnboardingWindow: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let flow = container.onboarding {
                OnboardingSteps(container: container, flow: flow)
            } else {
                // The flow is torn down when onboarding completes; the window follows it.
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(width: 460)
        .onAppear { _ = container.makeOnboardingFlow() }
    }
}

private struct OnboardingSteps: View {
    let container: AppContainer
    let flow: OnboardingFlow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch flow.step {
            case .bluetooth: bluetoothStep
            case .pickDevice: devicePickerStep
            case .calibrate: calibrationStep
            case .loginItem: loginItemStep
            case .finished: Color.clear.frame(height: 1)
            }

            if let error = flow.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .onChange(of: flow.step) { _, step in
            if step == .finished { dismiss() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch flow.step {
        case .bluetooth: return "Threshold needs Bluetooth"
        case .pickDevice: return "Choose the device you carry"
        case .calibrate: return "Teach Threshold your desk"
        case .loginItem, .finished: return "One last thing"
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .bluetooth:
            return """
                Threshold watches the Bluetooth signal strength of one device you carry, so it can \
                lock this Mac when you walk away. It never connects to the device, never reads \
                anything on it, and never handles your password.
                """
        case .pickDevice:
            return SupportedDevices.noiseNote
        case .calibrate:
            return "Two short measurements teach Threshold what \"at your desk\" and \"away\" look like on this Mac."
        case .loginItem, .finished:
            return "Threshold only protects your Mac while it is running."
        }
    }

    // MARK: - Step 1

    private var bluetoothStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("macOS will ask for permission the first time Threshold scans. Without it, automatic protection cannot run at all.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .font(.callout)

            Text(SupportedDevices.observationNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not now") { flow.cancel() }
                Spacer()
                Button("Start scanning") { flow.startScanning() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 2

    private var devicePickerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceList

            Toggle("Show every device (\(flow.hiddenDeviceCount) hidden)", isOn: Binding(
                get: { flow.showEveryDevice },
                set: { flow.showEveryDevice = $0 }
            ))
            .controlSize(.small)

            TextField("Name this device", text: Binding(
                get: { flow.deviceName },
                set: { flow.deviceName = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(flow.selection == nil)

            Text(SupportedDevices.observationNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { flow.cancel() }
                Spacer()
                Button("Continue") { flow.registerSelectedDevice() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canRegisterDevice)
            }
        }
    }

    private var deviceList: some View {
        Group {
            if flow.rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices that advertise a name…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
            } else {
                List(flow.rows, selection: Binding(
                    get: { flow.selection },
                    set: { if let id = $0 { flow.select(id) } }
                )) { row in
                    DeviceRow(row: row).tag(row.id)
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: - Step 3

    private var calibrationStep: some View {
        Group {
            if let device = container.model.registry.devices.first {
                CalibrationStepView(
                    container: container,
                    device: device,
                    onSuccess: { flow.calibrationSucceeded() },
                    onSkip: { flow.skipCalibration() }
                )
            } else {
                Text("No trusted device is registered.")
            }
        }
    }

    // MARK: - Step 4

    /// The optional permission, asked for last (system-integration.md §6).
    private var loginItemStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Open Threshold at login", isOn: Binding(
                get: { container.model.loginItemStatus == .known(.enabled) },
                set: { setLoginItem($0) }
            ))
            .toggleStyle(.switch)

            if case .known(let status) = container.model.loginItemStatus {
                HStack(spacing: 8) {
                    Text(PlainLanguage.loginItem(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status == .requiresApproval {
                        Button("Open Login Items…") { SystemSettingsLink.openLoginItems() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if !flow.didCalibrate {
                Label(
                    "Automatic locking stays off until calibration succeeds. You can run it any time from the menu.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { flow.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { container.refreshLoginItemStatus() }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try container.setLoginItemEnabled(enabled)
        } catch {
            flow.reportError("Threshold could not change the login item: \(String(describing: error))")
        }
    }
}

private struct DeviceRow: View {
    let row: DiscoveryRow

    var body: some View {
        HStack(spacing: 10) {
            SignalBars(filled: row.signalBars)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .fontWeight(row.hasName ? .medium : .regular)
                Text("\(row.rssi) dBm · seen \(row.sightings)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
