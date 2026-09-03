import Foundation

/// Minimal JSON rendering with a *stable key order*.
///
/// `JSONSerialization` is not used on purpose: it emits dictionary keys in an unspecified
/// order, and these lines are pasted into review reports and diffed between runs. A line
/// whose key order churns is unreadable as evidence.
///
/// A near-twin of `Tools/rssi-record`'s `JSONLine` and deliberately not shared: the two
/// tools are separate packages, and a shared helper would have to live in the app's own
/// sources, where a JSON writer for a developer tool has no business being.
enum JSONLine {

    /// Renders `{"k":v,...}` in exactly the order given. Values must already be rendered
    /// JSON (use `str`, `int`, `bool`, `null`, `array`).
    static func object(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\(str($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    static func int(_ value: some BinaryInteger) -> String { String(value) }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    static let null = "null"

    /// A measured value written the way a person would write it: `-63`, not `-63.0000`.
    /// Fixed-point throughout, so no exponent form and no locale separator can reach a line.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return null }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var rendered = String(format: "%.3f", value)
        while rendered.hasSuffix("0") { rendered.removeLast() }
        if rendered.hasSuffix(".") { rendered.removeLast() }
        return rendered
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

    /// An optional string as either a JSON string or `null`.
    ///
    /// A separate name rather than an overload of `str`: `array(items.map(JSONLine.str))` has
    /// to resolve to one function without the reader having to work out which.
    static func strOrNull(_ value: String?) -> String { value.map(str) ?? null }
}

/// One line of output.
///
/// Everything the tool says goes to **stdout** as one JSON object per line, including the
/// error line, so a run can be captured with a single redirect and replayed through `jq`.
/// Nothing is written to a file, and nothing goes to stderr: a smoke run's whole value is
/// the transcript, and splitting it across two streams loses the ordering between them.
func emit(_ kind: String, _ pairs: [(String, String)] = []) {
    let line = JSONLine.object([("kind", JSONLine.str(kind))] + pairs)
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// The tool's own failure, as opposed to a finding about the app.
struct SmokeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
