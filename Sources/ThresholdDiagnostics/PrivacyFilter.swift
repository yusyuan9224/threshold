import Foundation

/// De-identification rules applied to every event before it enters the ring buffer, so raw
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

    /// Rewrites every sensitive shape in a free-form message to a constant token.
    ///
    /// `message` is exported and logged just like `fields`, so it is exactly as sensitive; unlike a
    /// field it cannot simply be dropped without losing the reason the event was recorded, so each
    /// match is replaced in place instead. Tokens are constants, which keeps two recordings of the
    /// same message identical and keeps the result free of anything
    /// `DiagnosticsExportAnonymityCheck` would flag.
    static func redact(_ message: String) -> String {
        var result = message
        for rule in SensitivePatterns.redactionRules {
            result = rule.pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.token
            )
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
