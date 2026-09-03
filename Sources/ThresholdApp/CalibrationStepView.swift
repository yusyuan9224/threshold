import SwiftUI
import ThresholdAppKit
import ThresholdBluetooth
import ThresholdDomain

/// The two-phase calibration screen.
///
/// Near, then far, each until the §7.2 minimums are met: 20 seconds of coverage and 15
/// samples. The live sample count is on screen because a progress bar alone cannot tell the
/// user whether the wait is normal or whether their device simply is not being heard.
///
/// The view decides nothing. `CalibrationFlow` owns the stage, `CalibrationSession` owns the
/// verdict, and every failure sentence comes from `PlainLanguage`.
struct CalibrationStepView: View {
    let container: AppContainer
    let device: RegisteredDevice
    let onSuccess: () -> Void
    let onSkip: () -> Void

    @State private var flow: CalibrationFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let flow {
                content(flow)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear { flow = container.beginCalibration(device: device.id) }
        .onDisappear { container.endCalibration() }
    }

    @ViewBuilder
    private func content(_ flow: CalibrationFlow) -> some View {
        switch flow.stage {
        case .notStarted:
            instruction(
                icon: "chair.lounge",
                title: "Sit where you normally work",
                detail: "Keep \(device.name) where you usually keep it — pocket, desk, wrist. This step takes about \(secondsText) seconds.",
                primary: "Start",
                action: { flow.beginNear() }
            )

        case .measuring(let phase):
            measuring(flow, phase: phase)

        case .readyForFar:
            instruction(
                icon: "figure.walk.departure",
                title: "Now walk to where you usually leave",
                detail: "Go to the spot you would be standing when you would want this Mac locked — another room, the far side of the office. Then start the second measurement.",
                primary: "Start",
                action: { flow.beginFar() }
            )

        case .succeeded:
            VStack(alignment: .leading, spacing: 12) {
                Label("Calibration saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Threshold can now tell your desk from the spot you walked to.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Continue", action: onSuccess).keyboardShortcut(.defaultAction)
                }
            }

        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label(flow.failureMessage ?? "Calibration did not succeed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Skip for now", action: onSkip)
                    Spacer()
                    Button("Try again") { flow.beginNear() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func measuring(_ flow: CalibrationFlow, phase: CalibrationPhase) -> some View {
        let complete = flow.isComplete(phase)
        return VStack(alignment: .leading, spacing: 12) {
            Text(phase == .near ? "Measuring at your desk" : "Measuring away from your desk")
                .font(.headline)

            ProgressView(value: flow.progress(for: phase))
                .progressViewStyle(.linear)

            Text("\(flow.sampleCount(for: phase)) readings · \(flow.elapsed(for: phase).displaySeconds)s of \(secondsText)s")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if flow.sampleCount(for: phase) == 0 {
                Text("Nothing heard from \(device.name) yet. Make sure it is switched on and nearby.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Skip for now", action: onSkip)
                Spacer()
                Button(phase == .near ? "Continue" : "Finish") {
                    if phase == .near {
                        flow.completeNear()
                    } else {
                        finish(flow)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!complete)
            }
        }
    }

    private func instruction(icon: String, title: String, detail: String, primary: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip for now", action: onSkip)
                Spacer()
                Button(primary, action: action).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Evaluate, then persist. A save failure moves the flow to `.failed` so the screen never
    /// claims success over a record that was not written.
    private func finish(_ flow: CalibrationFlow) {
        guard case .success(let record) = flow.finish(environment: container.calibrationEnvironment) else { return }
        do {
            try container.applyCalibration(record)
        } catch {
            flow.saveFailed(StoreErrorText.describe(error))
        }
    }

    private var secondsText: String {
        String(container.calibrationPolicy.minDuration.displaySeconds)
    }
}
