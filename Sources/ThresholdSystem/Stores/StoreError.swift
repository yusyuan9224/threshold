import Foundation

/// Why a store could not read or write.
///
/// Every case names the file, never its directory: these errors reach diagnostics, and the
/// containing path is under the user's home (ADR-007, security.md §3). For the same reason the
/// `message` payloads carry an error domain and code or a decoding description, not a system error
/// string that may embed the path.
public enum StoreError: Error, Equatable, Sendable {
    /// The Application Support location could not be resolved, or the identifier was unusable.
    case directoryUnavailable(String)
    case readFailed(file: String, message: String)
    case decodeFailed(file: String, message: String)
    /// The file was written by a version of the app this one cannot read. Never repaired silently:
    /// a store that resets itself on a decode failure loses the user's trusted devices and their
    /// calibration without telling them.
    case unsupportedSchemaVersion(file: String, found: Int, supported: Int)
    case encodeFailed(file: String, message: String)
    case writeFailed(file: String, message: String)
}

/// A short, path-free description of a foreign error.
func storeErrorMessage(for error: any Error) -> String {
    if let decoding = error as? DecodingError { return String(describing: decoding) }
    if let encoding = error as? EncodingError { return String(describing: encoding) }
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
}
