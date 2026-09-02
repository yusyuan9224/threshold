import Foundation

/// De-identification rules applied to every field before it enters the ring buffer, so raw
/// sensitive values never enter `DiagnosticsRecorder`'s storage (ADR-007).
enum PrivacyFilter {
    /// Filters `fields`, aliasing device identifiers via `deviceAlias` and dropping anything that
    /// looks like a credential or a raw identifier/MAC/e-mail. Adds `"redacted": .bool(true)`
    /// whenever at least one field was dropped, so the loss is visible in the event itself.
    static func apply(
        to fields: [String: DiagnosticEvent.FieldValue],
        deviceAlias: inout DeviceAlias
    ) -> [String: DiagnosticEvent.FieldValue] {
        var result: [String: DiagnosticEvent.FieldValue] = [:]
        var didRedact = false

        for (key, value) in fields {
            let lowerKey = key.lowercased()

            if isSensitiveKey(lowerKey) {
                didRedact = true
                continue
            }

            if isDeviceKey(lowerKey), case .string(let raw) = value {
                result[key] = .string(deviceAlias.alias(for: raw))
                continue
            }

            if case .string(let stringValue) = value, looksSensitive(stringValue) {
                didRedact = true
                continue
            }

            result[key] = value
        }

        if didRedact {
            result["redacted"] = .bool(true)
        }
        return result
    }

    private static func isSensitiveKey(_ lowerKey: String) -> Bool {
        lowerKey.contains("password") || lowerKey.contains("passcode") || lowerKey.contains("credential")
    }

    private static func isDeviceKey(_ lowerKey: String) -> Bool {
        lowerKey.hasSuffix("deviceid") || lowerKey.hasSuffix("identifier") || lowerKey.hasSuffix("device")
    }

    private static func looksSensitive(_ value: String) -> Bool {
        SensitivePatterns.uuid.hasMatch(in: value)
            || SensitivePatterns.macAddress.hasMatch(in: value)
            || SensitivePatterns.email.hasMatch(in: value)
    }
}

/// Regexes shared with `DiagnosticsExportAnonymityCheck`, which scans whole export blobs for the
/// same shapes rather than individual field values.
enum SensitivePatterns {
    static let uuid = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )
    static let macAddress = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"
    )
    static let email = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    )
    static let localHostname = try! NSRegularExpression(
        pattern: "\\b[A-Za-z0-9-]+\\.local\\b"
    )
}

extension NSRegularExpression {
    func hasMatch(in string: String) -> Bool {
        firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
