import Foundation
import ThresholdDomain

/// Minimal JSON rendering with a *stable key order*.
///
/// `JSONSerialization` is not used on purpose: it emits dictionary keys in an
/// unspecified order, and these lines end up in `Tests/Fixtures/BLE/` where a human
/// reviews the diff before the file is committed. A fixture whose key order churns
/// between runs is unreviewable.
enum JSONLine {

    /// Renders `{"k":v,...}` in exactly the order given. Values must already be
    /// rendered JSON (use `str`, `int`, `bool`, `fixed`, `array`).
    static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\(str($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    static func int(_ value: some BinaryInteger) -> String { String(value) }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    /// Fixed-point rather than `String(describing:)`: no exponent form, no
    /// locale-dependent separator, and a stable number of digits across runs.
    static func fixed(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    /// A JSON string literal, escaped per RFC 8259.
    static func str(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension SensorStatus {
    /// The fixture spelling of a sensor status: `available`, `degraded.<reason>`,
    /// `unavailable.<reason>`.
    ///
    /// Written by hand rather than derived from `Codable` so the fixture format is
    /// pinned here and cannot drift when the Domain's `Codable` synthesis changes.
    var fixtureName: String {
        switch self {
        case .available: "available"
        case .degraded(let reason): "degraded.\(reason.rawValue)"
        case .unavailable(let reason): "unavailable.\(reason.rawValue)"
        }
    }

    /// `true` for statuses no amount of waiting will clear: the operator has to grant
    /// permission or use different hardware. Recording through one of these would
    /// produce a file with no observations in it.
    ///
    /// `.poweredOff` and `.degraded(_)` are deliberately *not* fatal during a
    /// recording — they are the very transitions the `bluetooth-off` and
    /// `wake-after-sleep` fixtures exist to capture.
    var isUnrecoverable: Bool {
        switch self {
        case .unavailable(.unauthorized), .unavailable(.unsupported): true
        default: false
        }
    }
}
