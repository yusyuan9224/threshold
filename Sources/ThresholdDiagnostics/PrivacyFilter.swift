import Foundation

/// De-identification rules applied to every event before it enters the ring buffer, so raw
/// sensitive values never enter `DiagnosticsRecorder`'s storage (ADR-007).
enum PrivacyFilter {
    /// Filters `fields` in a fixed order: credential keys are dropped, device-identifying keys are
    /// aliased via `deviceAlias`, person/host name keys are dropped, and any remaining string whose
    /// *value* matches a catalogued sensitive shape is dropped. Adds `"redacted": .bool(true)`
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

            if isPersonalStringKey(lowerKey), case .string = value {
                didRedact = true
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

    /// Keys whose string value identifies a *device* — address, CoreBluetooth identifier, or the
    /// advertised name, all of which pin down one physical device — and so get a stable alias.
    ///
    /// Deliberately narrow: a bare `identifier` suffix would also catch the ADR-006 lifecycle IDs
    /// (`actionIdentifier`, `episodeIdentifier`), and aliasing those would both destroy the
    /// correlation they exist for and make unrelated actions read as the same device.
    private static func isDeviceKey(_ lowerKey: String) -> Bool {
        guard !isLifecycleKey(lowerKey) else { return false }
        return lowerKey.contains("device") || lowerKey.contains("peripheral")
    }

    private static func isLifecycleKey(_ lowerKey: String) -> Bool {
        lowerKey.hasPrefix("action") || lowerKey.hasPrefix("episode") || lowerKey.hasPrefix("transition")
    }

    /// Keys that carry a person's or host's name rather than a device's. There is no alias worth
    /// assigning here — the value is dropped. Checked after `isDeviceKey`, so `deviceName` is
    /// aliased rather than lost.
    private static func isPersonalStringKey(_ lowerKey: String) -> Bool {
        let markers = ["name", "hostname", "host", "localname", "serial", "appleid", "account", "user"]
        return markers.contains { lowerKey.contains($0) }
    }

    /// A value is sensitive if it matches *any* catalogued shape. Consulting the whole catalogue is
    /// what keeps this filter and `DiagnosticsExportAnonymityCheck` from disagreeing — a shape the
    /// check would flag on export must never be storable in the first place.
    private static func looksSensitive(_ value: String) -> Bool {
        SensitivePatterns.all.contains { $0.hasMatch(in: value) }
    }
}
