import Foundation
import ThresholdBluetooth
import ThresholdDomain

/// One row of the discovery table.
struct DiscoveryRow {
    let identifier: String
    let name: String
    let medianRSSI: Int
    let sightings: Int
    let droppedInvalidRSSI: Int
}

/// Aggregates `DiscoveredDevice` events. Separate from `Recording` because discovery
/// results are the one place identifiers and advertised names are legitimately
/// handled (bluetooth.md §2) — and they must never reach a fixture.
actor DiscoveryTable {
    private struct Entry {
        var name: String?
        var rssis: [Int] = []
        var dropped = 0
    }

    private var entries: [DeviceID: Entry] = [:]

    func add(_ device: DiscoveredDevice) {
        var entry = entries[device.id] ?? Entry()
        // Keep the first advertised name seen: some devices alternate between a named
        // and an unnamed advertisement, and a blank name is less useful than a stale one.
        if entry.name == nil { entry.name = device.advertisedName }
        if device.rssi == 127 {
            entry.dropped += 1
        } else {
            entry.rssis.append(device.rssi)
        }
        entries[device.id] = entry
    }

    /// Strongest-signal devices are rarely the ones you want; most-heard ones are.
    /// Sorted by sighting count, descending, with the identifier as a stable tiebreak.
    func rows() -> [DiscoveryRow] {
        entries
            .map { id, entry in
                let sorted = entry.rssis.sorted()
                return DiscoveryRow(
                    identifier: id.raw,
                    name: entry.name ?? "—",
                    medianRSSI: sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                    sightings: entry.rssis.count + entry.dropped,
                    droppedInvalidRSSI: entry.dropped
                )
            }
            .sorted { lhs, rhs in
                lhs.sightings == rhs.sightings
                    ? lhs.identifier < rhs.identifier
                    : lhs.sightings > rhs.sightings
            }
    }
}

/// `rssi-record discover <seconds>` — the "which of these is my phone?" step.
///
/// Prints identifiers, which is exactly what `record --device` needs and exactly
/// what must never be pasted anywhere else. Output goes to stdout; the tool never
/// writes it to a file.
enum DiscoverCommand {

    static func run(seconds duration: Int) async throws {
        let clock = ContinuousBLEClock()
        let scanner = CoreBluetoothScanner(clock: clock)
        let table = DiscoveryTable()
        let watch = SensorWatch()

        note("Discovering for \(duration)s …")
        let stream = scanner.discover()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await device in stream { await table.add(device) }
            }
            group.addTask {
                for await status in scanner.sensorStates {
                    await watch.note(status.value)
                    note("sensor \(status.value.fixtureName)")
                    // Discovery has nothing to salvage from a bad radio, so *any*
                    // `.unavailable` aborts here — including `.poweredOff`, which
                    // during a recording would just be data. Failing fast is the
                    // requirement: a denied process must exit, not hang for the
                    // full duration.
                    if case .unavailable = status.value {
                        throw ToolError("Bluetooth is \(status.value.fixtureName) — cannot discover")
                    }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(duration)) }
            try await group.next()
            group.cancelAll()
        }

        scanner.stopDiscovery()

        if let reason = await watch.unusableReason() { throw ToolError(reason) }

        printTable(await table.rows())
    }

    private static func printTable(_ rows: [DiscoveryRow]) {
        // stdout, so the table can be piped or copied. Everything else this command
        // says goes to stderr.
        print(row("IDENTIFIER", "NAME", "MEDIAN", "SIGHTINGS"))
        for entry in rows {
            print(
                row(
                    entry.identifier,
                    entry.name,
                    "\(entry.medianRSSI)",
                    "\(entry.sightings)"
                )
            )
        }
        note("")
        note("\(rows.count) device(s). Identifiers are for LOCAL USE ONLY — pass one to")
        note("`rssi-record record --device <identifier>`; never put one in a fixture,")
        note("a commit message, an issue or a spec.")
    }

    private static func row(_ identifier: String, _ name: String, _ median: String, _ sightings: String) -> String {
        pad(identifier, 38)
            + pad(truncate(name, to: 28), 30)
            + pad(median, 8, right: true)
            + pad(sightings, 11, right: true)
    }

    private static func pad(_ value: String, _ width: Int, right: Bool = false) -> String {
        let used = displayWidth(value)
        guard used < width else { return value + " " }
        let spaces = String(repeating: " ", count: width - used)
        return right ? spaces + value : value + spaces
    }

    private static func truncate(_ value: String, to width: Int) -> String {
        guard displayWidth(value) > width else { return value }
        var out = ""
        for character in value where displayWidth(out) + displayWidth(String(character)) <= width - 1 {
            out.append(character)
        }
        return out + "…"
    }

    /// Terminal columns, not characters. Advertised names are routinely CJK ("主臥",
    /// "…的 Mac mini"), and those glyphs occupy two columns each — padding by
    /// `String.count` shears the table apart exactly for the users most likely to
    /// run this.
    private static func displayWidth(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { width, scalar in
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
                 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x20000...0x3FFFD:
                width + 2
            default:
                width + 1
            }
        }
    }
}
