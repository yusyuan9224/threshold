import SwiftUI
import ThresholdAppKit
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// Settings: the policy switches, the silence timeout, launch-at-login, and the trusted
/// device itself.
///
/// Every control writes through `AppContainer`, which persists immediately. Nothing here
/// mutates `PolicySettings` in place — settings are a value type that travels to the engine
/// as an event (architecture.md §4.3), so there is no shared mutable configuration object for
/// a view to reach into.
struct SettingsWindow: View {
    let container: AppContainer
    @State private var failure: String?

    private var model: AppModel { container.model }

    var body: some View {
        Form {
            Section("Automatic protection") {
                Toggle("Lock when I leave", isOn: binding(\.autoLock, container.setAutoLock))
                Toggle("Wake the display when I return", isOn: binding(\.wakeOnReturn, container.setWakeOnReturn))
                Toggle("Also lock when my device fades and then goes silent",
                       isOn: binding(\.lockOnDepartureThenSilent, container.setLockOnDepartureThenSilent))
                Text("Fading then falling silent is stronger evidence than sudden silence, but it is still not proof that you left. Turning this off means Threshold only locks on a measured signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("If your device simply goes quiet") {
                Picker("Lock after", selection: silenceSelection) {
                    Text("Never").tag(SilenceChoice.never)
                    ForEach(SilenceChoice.timeouts, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Text("A silent device is lost evidence, not proof of absence, so Threshold also needs to see that you have not touched the keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Open Threshold at login", isOn: Binding(
                    get: { model.loginItemStatus == .known(.enabled) },
                    set: { setLoginItem($0) }
                ))
                if case .known(let status) = model.loginItemStatus {
                    Text(PlainLanguage.loginItem(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Trusted device") {
                if model.registry.devices.isEmpty {
                    Text("No device is set up yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.registry.devices, id: \.id) { device in
                        TrustedDeviceRow(container: container, device: device, failure: $failure)
                    }
                }
                Text(SupportedDevices.shortNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Calibration") {
                Text(gateDescription)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset calibration") { resetCalibration() }
                    .disabled(!model.hasTrustedDevice)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { container.refreshLoginItemStatus() }
        .alert("Something could not be saved", isPresented: showingFailure) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Bindings

    private func binding(_ keyPath: KeyPath<PolicySettings, Bool>, _ setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { setter($0) })
    }

    private var showingFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private var silenceSelection: Binding<SilenceChoice> {
        Binding(
            get: { SilenceChoice(model.settings.silenceLock) },
            set: { container.setSilenceLock($0.policy) }
        )
    }

    private var gateDescription: String {
        switch model.calibrationGate {
        case .armed: return "Calibrated. Automatic protection can run."
        case .notArmed(let reason): return PlainLanguage.notArmed(reason)
        }
    }

    // MARK: - Actions

    private func setLoginItem(_ enabled: Bool) {
        do {
            try container.setLoginItemEnabled(enabled)
        } catch {
            failure = String(describing: error)
        }
    }

    private func resetCalibration() {
        do {
            try container.resetCalibration()
        } catch {
            failure = StoreErrorText.describe(error)
        }
    }
}

/// The silence-lock picker's options, as a `Hashable` tag type.
///
/// `SilenceLockPolicy.never` is a distinct case rather than a zero timeout, and this enum keeps
/// that distinction intact through the picker: "never" is a decision, not the smallest number.
enum SilenceChoice: Hashable {
    case never
    case after(seconds: Int64)

    static let timeouts: [SilenceChoice] = [
        .after(seconds: 60), .after(seconds: 180), .after(seconds: 300), .after(seconds: 600),
    ]

    init(_ policy: SilenceLockPolicy) {
        switch policy {
        case .never: self = .never
        case .afterTimeout(let duration): self = .after(seconds: duration.components.seconds)
        }
    }

    var policy: SilenceLockPolicy {
        switch self {
        case .never: return .never
        case .after(let seconds): return .afterTimeout(.seconds(seconds))
        }
    }

    var label: String {
        switch self {
        case .never: return "Never"
        case .after(let seconds):
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
    }
}

private struct TrustedDeviceRow: View {
    let container: AppContainer
    let device: RegisteredDevice
    @Binding var failure: String?

    @State private var name: String = ""
    @State private var confirmingRemoval = false

    var body: some View {
        HStack {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rename() }
            Button("Remove") { confirmingRemoval = true }
        }
        .onAppear { name = device.name }
        .confirmationDialog(
            "Remove \(device.name)?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove device and calibration", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its calibration is removed too, because a profile only means anything for the device it was measured from. Automatic protection stops until you set up a device again.")
        }
    }

    private func rename() {
        do {
            try container.renameDevice(device.id, to: name)
        } catch {
            failure = StoreErrorText.describe(error)
            name = device.name
        }
    }

    private func remove() {
        do {
            try container.removeDevice(device.id)
        } catch {
            failure = StoreErrorText.describe(error)
        }
    }
}
