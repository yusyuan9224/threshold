import Foundation

/// Last line of defense before an export leaves the machine (e.g. attached to an issue report):
/// scans the exported bytes themselves for shapes that should never survive `PrivacyFilter`.
public enum DiagnosticsExportAnonymityCheck {
    /// Returns a human-readable finding per problem shape detected in `data`; empty means clean.
    public static func findings(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else {
            return ["export is not valid UTF-8"]
        }

        var findings: [String] = []
        if SensitivePatterns.uuid.hasMatch(in: text) {
            findings.append("UUID-shaped identifier found in export")
        }
        if SensitivePatterns.macAddress.hasMatch(in: text) {
            findings.append("MAC-address-shaped value found in export")
        }
        if SensitivePatterns.email.hasMatch(in: text) {
            findings.append("e-mail address found in export")
        }
        if SensitivePatterns.localHostname.hasMatch(in: text) {
            findings.append(".local hostname found in export")
        }
        if text.contains("/Users/") {
            findings.append("absolute home path found in export")
        }
        return findings
    }
}
