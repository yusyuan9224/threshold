import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let usage = """
rssi-record 0.1 — MVP 1B field recorder (docs/specs/testing.md §3, SPIKE-009 §A/§B/§C)

USAGE
  rssi-record discover <seconds>
      Scan for advertising devices and print a table of what is nearby.
      Identifiers are printed for LOCAL USE ONLY — never paste them into a
      fixture, a commit message, an issue or a spec.

  rssi-record record --device <identifier> [--device <identifier> ...]
                     --scenario <name>
                     --mac-class laptop|desktop
                     --device-class iphone|watch|beacon
                     --seconds <n>
                     --out <file.jsonl>
      Record an ANONYMISED fixture. Identifiers are mapped to device-A,
      device-B, ... in the order they appear on the command line and never
      reach the output file.

SCENARIO NAMES (SPIKE-009 §C and the fixture set in testing.md §3)
  desk-1m  pocket-3m  next-room-8m  device-locked-idle-30m
  walking-away  walking-back  bluetooth-off  wake-after-sleep
  Lowercase letters, digits and hyphens only.
"""

/// `record` arguments, already validated.
struct RecordOptions {
    /// Canonical (uppercase) CoreBluetooth identifiers, in the order the operator
    /// gave them. Position is what assigns `device-A`, `device-B`, ...
    let devices: [UUID]
    let scenario: String
    let macClass: String
    let deviceClass: String
    let seconds: Int
    let outputPath: String

    static let macClasses = ["laptop", "desktop"]
    static let deviceClasses = ["iphone", "watch", "beacon"]
    /// 26 aliases: `device-A` ... `device-Z`.
    static let maxDevices = 26
    static let maxSeconds = 24 * 60 * 60

    static func parse(_ arguments: [String]) throws -> RecordOptions {
        var devices: [UUID] = []
        var scenario: String?
        var macClass: String?
        var deviceClass: String?
        var seconds: String?
        var outputPath: String?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard let value = arguments[safe: index + 1] else {
                throw ToolError("\(flag) needs a value")
            }
            switch flag {
            case "--device": devices.append(try canonicalUUID(value))
            case "--scenario": scenario = value
            case "--mac-class": macClass = value
            case "--device-class": deviceClass = value
            case "--seconds": seconds = value
            case "--out": outputPath = value
            default: throw ToolError("unknown option \(flag)")
            }
            index += 2
        }

        guard !devices.isEmpty else { throw ToolError("at least one --device is required") }
        guard devices.count <= maxDevices else {
            throw ToolError("at most \(maxDevices) devices (one alias per letter)")
        }
        guard Set(devices).count == devices.count else {
            throw ToolError("the same --device was given twice")
        }

        return RecordOptions(
            devices: devices,
            scenario: try validScenario(scenario),
            macClass: try oneOf(macClass, macClasses, flag: "--mac-class"),
            deviceClass: try oneOf(deviceClass, deviceClasses, flag: "--device-class"),
            seconds: try validSeconds(seconds),
            outputPath: try require(outputPath, flag: "--out")
        )
    }

    /// Uppercases and re-renders through `UUID` so the value matches the `DeviceID`
    /// the scanner produces (`CBPeripheral.identifier.uuidString`, uppercase)
    /// regardless of how the operator pasted it.
    private static func canonicalUUID(_ raw: String) throws -> UUID {
        guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw ToolError("--device is not a UUID (run `rssi-record discover` to find one)")
        }
        return uuid
    }

    /// The scenario name is the only free-text field that reaches the fixture, so it
    /// is restricted rather than escaped: a device's advertised name must not be able
    /// to slip into a file that is supposed to be anonymised.
    private static func validScenario(_ raw: String?) throws -> String {
        let value = try require(raw, flag: "--scenario")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !value.isEmpty, value.count <= 64,
              value.allSatisfy({ allowed.contains($0) }),
              value.first != "-", value.last != "-"
        else {
            throw ToolError("--scenario must be lowercase letters, digits and hyphens (e.g. desk-1m)")
        }
        return value
    }

    private static func validSeconds(_ raw: String?) throws -> Int {
        let value = try require(raw, flag: "--seconds")
        guard let seconds = Int(value), seconds >= 1, seconds <= maxSeconds else {
            throw ToolError("--seconds must be between 1 and \(maxSeconds)")
        }
        return seconds
    }

    private static func oneOf(_ raw: String?, _ allowed: [String], flag: String) throws -> String {
        let value = try require(raw, flag: flag)
        guard allowed.contains(value) else {
            throw ToolError("\(flag) must be one of \(allowed.joined(separator: "|"))")
        }
        return value
    }

    private static func require(_ raw: String?, flag: String) throws -> String {
        guard let raw else { throw ToolError("\(flag) is required") }
        return raw
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
