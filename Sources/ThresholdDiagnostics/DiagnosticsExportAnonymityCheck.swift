import Foundation

/// Last line of defense before an export leaves the machine (e.g. attached to an issue report):
/// scans the exported bytes themselves for shapes that should never survive `PrivacyFilter`.
///
/// Every shape checked here has a matching redaction rule in `SensitivePatterns.redactionRules`,
/// so a correctly filtered event can never trip it — see the note there.
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
        if SensitivePatterns.possessiveDeviceName.hasMatch(in: text) {
            findings.append("owner-named device found in export")
        }
        if SensitivePatterns.homePath.hasMatch(in: text) {
            findings.append("absolute home path found in export")
        }
        return findings
    }
}
