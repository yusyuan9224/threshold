import ThresholdBluetooth
import ThresholdDomain

/// One row of the "pick your device" list.
///
/// `sightings` is on the row because it is the only cheap signal a user has for telling a
/// real device from noise. SPIKE-009 saw 56 distinct identifiers in a ten-minute scan of one
/// ordinary room, twelve of which lived under ten seconds; a picker that lists all of them
/// with equal weight is unusable. A device seen forty times is a device; one seen twice is
/// probably a passing advertisement with a rotating address.
public struct DiscoveryRow: Identifiable, Sendable, Equatable {
    public let id: DeviceID
    /// `nil` when the advertisement carried no local name — common, and not a defect.
    public let advertisedName: String?
    /// The most recent RSSI, in dBm.
    public let rssi: Int
    /// How many advertisements from this identifier this discovery session has seen.
    public let sightings: Int
    public let firstSeen: MonotonicInstant
    public let lastSeen: MonotonicInstant

    public var displayName: String { advertisedName ?? "Unnamed device" }
    public var hasName: Bool { advertisedName != nil }

    /// 0–4 bars. Boundaries are display-only rounding of the dBm scale and have no bearing on
    /// any Domain threshold — presence uses the calibrated profile, never these numbers.
    public var signalBars: Int {
        switch rssi {
        case ..<(-90): return 0
        case ..<(-80): return 1
        case ..<(-70): return 2
        case ..<(-60): return 3
        default: return 4
        }
    }
}

/// Accumulates a discovery stream into a stable, sorted list.
///
/// A value type with no clock and no concurrency: the view feeds it `DiscoveredDevice`s and
/// reads `rows` back, which makes the whole "what does the picker show" question testable
/// without a scanner, a run loop or a timeout.
public struct DiscoveryTable: Sendable, Equatable {

    private struct Entry: Sendable, Equatable {
        let advertisedName: String?
        let rssi: Int
        let sightings: Int
        let firstSeen: MonotonicInstant
        let lastSeen: MonotonicInstant
    }

    private var entries: [DeviceID: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    /// Every identifier heard, including the noise the picker hides by default.
    public var totalSeen: Int { entries.count }

    /// Folds one advertisement in.
    ///
    /// A name once advertised is kept even if later advertisements omit it: Apple devices
    /// interleave named and unnamed packets, and a row whose label flickers between the
    /// device's name and "Unnamed device" is worse than one that remembers.
    public mutating func ingest(_ device: DiscoveredDevice) {
        guard let existing = entries[device.id] else {
            entries[device.id] = Entry(
                advertisedName: device.advertisedName,
                rssi: device.rssi,
                sightings: 1,
                firstSeen: device.at,
                lastSeen: device.at
            )
            return
        }
        entries[device.id] = Entry(
            advertisedName: device.advertisedName ?? existing.advertisedName,
            rssi: device.rssi,
            sightings: existing.sightings + 1,
            firstSeen: min(existing.firstSeen, device.at),
            lastSeen: max(existing.lastSeen, device.at)
        )
    }

    public mutating func reset() { entries.removeAll() }

    /// Rows in the order the picker shows them.
    ///
    /// Named devices first, then strongest signal, then most sightings, then identifier for a
    /// stable tie-break. Sorting by name-then-strength rather than by strength alone is a
    /// deliberate bias towards the thing the user is looking for: their own phone on their own
    /// desk advertises a name and sits at the top of the list, while the anonymous −95 dBm
    /// traffic of a block of flats stays below it.
    ///
    /// - Parameter namedOnly: hide identifiers that never advertised a name. On by default
    ///   because of the SPIKE-009 noise floor; the UI offers a switch to see everything, since
    ///   a generic BLE beacon is a legitimate choice that may never carry a name.
    public func rows(namedOnly: Bool = true) -> [DiscoveryRow] {
        entries
            .filter { !namedOnly || $0.value.advertisedName != nil }
            .map { id, entry in
                DiscoveryRow(
                    id: id,
                    advertisedName: entry.advertisedName,
                    rssi: entry.rssi,
                    sightings: entry.sightings,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen
                )
            }
            .sorted { lhs, rhs in
                if lhs.hasName != rhs.hasName { return lhs.hasName }
                if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
                if lhs.sightings != rhs.sightings { return lhs.sightings > rhs.sightings }
                return lhs.id.raw < rhs.id.raw
            }
    }
}
