import AppKit
import SwiftUI
import ThresholdAppKit
import ThresholdDiagnostics

/// "Export diagnostics…" — a save panel, then bytes.
///
/// The order is the point. `DiagnosticsRecorder.export()` runs its own anonymity check and
/// throws `DiagnosticsExportError.anonymityViolation` rather than returning data, so the
/// export is produced **before** any file is created and nothing is written when the check
/// fails. A partially written file the user might attach to a public issue is precisely the
/// leak the fail-closed design exists to prevent (ADR-007).
struct DiagnosticsExportButton: View {
    let container: AppContainer
    @State private var failure: String?
    @State private var isExporting = false

    var body: some View {
        Button("Export diagnostics…") { export() }
            .disabled(isExporting)
            .alert("Diagnostics were not exported", isPresented: showingFailure) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    private var showingFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    }

    private func export() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            let data: Data
            do {
                data = try await container.exportDiagnostics()
            } catch let error as DiagnosticsExportError {
                failure = describe(error)
                return
            } catch {
                failure = String(describing: error)
                return
            }

            guard let url = presentSavePanel() else { return }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                failure = "The file could not be written."
            }
        }
    }

    /// The findings name the *kind* of value that leaked, never the value, so they are safe to
    /// put in front of the user — and telling them is better than a generic failure, because a
    /// finding here is a bug report worth filing.
    private func describe(_ error: DiagnosticsExportError) -> String {
        switch error {
        case .anonymityViolation(let findings):
            let list = findings.joined(separator: "\n• ")
            return """
                Threshold found identifying data in the diagnostics and refused to write the file. \
                Nothing was saved.

                • \(list)
                """
        }
    }

    private func presentSavePanel() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "threshold-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
