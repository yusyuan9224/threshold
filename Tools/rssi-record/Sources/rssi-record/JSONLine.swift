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

    /// A measured value written the way a person would write it: `-55`, not
    /// `-55.0000`, and `4.5` rather than `4.5000`. Used for the calibration profile,
    /// whose numbers are read and hand-edited far more often than the run metrics.
    /// Still fixed-point, so no exponent form can reach the file.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var rendered = fixed(value, places: 4)
        while rendered.hasSuffix("0") { rendered.removeLast() }
        if rendered.hasSuffix(".") { rendered.removeLast() }
        return rendered
    }

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
