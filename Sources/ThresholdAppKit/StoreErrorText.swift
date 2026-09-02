import ThresholdSystem

/// Turns a `StoreError` into a sentence a user can act on.
///
/// Every case here names the file and the nature of the problem and nothing else. That is not
/// politeness, it is the same rule `StoreError` itself follows: these strings reach the UI and
/// the diagnostics export, and the containing directory is under the user's home, so a path
/// must never be interpolated into them (ADR-007, security.md §3).
///
/// `unsupportedSchemaVersion` gets the longest sentence because it is the one case where doing
/// nothing is correct. A store that "repairs" a file it cannot read throws away the user's
/// trusted devices and their calibration without telling them, so the app reports the version
/// mismatch and stops.
public enum StoreErrorText {

    public static func describe(_ error: any Error) -> String {
        guard let error = error as? StoreError else { return String(describing: error) }
        switch error {
        case .directoryUnavailable(let detail):
            return "Threshold could not find its Application Support folder (\(detail))"
        case .readFailed(let file, let message):
            return "\(file) could not be read (\(message))"
        case .decodeFailed(let file, let message):
            return "\(file) is not in a format this version understands (\(message))"
        case .unsupportedSchemaVersion(let file, let found, let supported):
            return "\(file) was written by a newer version of Threshold (format \(found); this version reads \(supported)). Nothing was changed."
        case .encodeFailed(let file, let message):
            return "\(file) could not be prepared for saving (\(message))"
        case .writeFailed(let file, let message):
            return "\(file) could not be saved (\(message))"
        }
    }
}
