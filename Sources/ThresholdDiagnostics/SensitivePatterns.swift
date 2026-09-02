import Foundation

/// The single catalogue of shapes ADR-007 forbids in diagnostics. Three consumers share it, and
/// they must stay in lockstep: `PrivacyFilter` drops matching field values, `PrivacyFilter.redact`
/// rewrites matches inside free-form messages, and `DiagnosticsExportAnonymityCheck` scans whole
/// export blobs for anything that slipped through.
///
/// Because `export()` fails closed on any finding, every pattern listed here must also have a
/// redaction rule below — otherwise a single unfiltered event would permanently break exporting.
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
    /// Apple's default device names carry the owner's name: "Someone's iPhone", "Someone’s MacBook Pro".
    /// The owner part is deliberately a single token, so the match starts at the name rather than
    /// swallowing the whole sentence before it; a multi-word owner name loses only its last word here,
    /// which is why name-shaped *keys* are redacted outright in `PrivacyFilter`.
    static let possessiveDeviceName = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}._-]*['\u{2019}]s\\s+"
            + "(?:iPhone|iPad|iPod(?:\\s+touch)?|MacBook\\s+Pro|MacBook\\s+Air|MacBook"
            + "|iMac(?:\\s+Pro)?|Mac\\s+mini|Mac\\s+Studio|Mac\\s+Pro|Mac"
            + "|Apple\\s+Watch|Watch|AirPods(?:\\s+Pro|\\s+Max)?)\\b"
    )
    /// A home directory path names the account holder.
    static let homePath = try! NSRegularExpression(
        pattern: "/Users/[^/\\s\"]+"
    )

    /// One redaction rule per pattern, applied in this order. Replacement tokens are constants —
    /// the same input always yields the same output, so redacted messages stay diffable and
    /// greppable — and no token itself matches any pattern.
    static let redactionRules: [(pattern: NSRegularExpression, token: String)] = [
        (uuid, "<redacted:uuid>"),
        (macAddress, "<redacted:mac>"),
        (email, "<redacted:email>"),
        (localHostname, "<redacted:hostname>"),
        (possessiveDeviceName, "<redacted:device-name>"),
        (homePath, "<redacted:path>"),
    ]

    /// Every pattern, for callers that only need "does this look sensitive at all".
    static let all: [NSRegularExpression] = redactionRules.map(\.pattern)
}

extension NSRegularExpression {
    func hasMatch(in string: String) -> Bool {
        firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
