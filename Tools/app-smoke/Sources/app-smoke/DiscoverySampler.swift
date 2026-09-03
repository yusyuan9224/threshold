import ThresholdAppKit
import ThresholdDomain

/// A median RSSI per device, sampled from the picker's own table.
///
/// `DiscoveryTable` keeps only the *latest* RSSI per identifier, because that is all the
/// device picker renders. A median is still what you want in a field report — one packet
/// caught at −92 dBm says nothing about where a phone was sitting — so this samples the
/// table on a fixed interval and takes the median of what it saw.
///
/// The alternative would have been a second tap on the discovery stream, and that is exactly
/// the thing this tool must not do: `BLEScanning.discover()` is single-consumer, the
/// container's `discoveryTask` is that consumer, and a tool that opened its own would be
/// measuring a scan the app is not running. Sampling the same rows the UI draws keeps the
/// evidence about the app.
///
/// `samples` is therefore a lower bound on `sightings`: advertisements that arrive between
/// two polls collapse into one sample. Both numbers are printed so the reader can see the
/// basis rather than infer it.
struct DiscoverySampler {

    private struct Entry {
        var rssis: [Int] = []
        var lastSightings = 0
    }

    private var entries: [DeviceID: Entry] = [:]

    /// Folds one poll of `OnboardingFlow.rows` in.
    ///
    /// A row whose `sightings` has not moved since the last poll contributes nothing: its
    /// `rssi` is the same packet already counted, and re-adding it would weight a device that
    /// went quiet towards whatever value it fell silent on.
    mutating func sample(_ rows: [DiscoveryRow]) {
        for row in rows {
            var entry = entries[row.id] ?? Entry()
            if row.sightings > entry.lastSightings {
                entry.rssis.append(row.rssi)
                entry.lastSightings = row.sightings
            }
            entries[row.id] = entry
        }
    }

    /// The median of the sampled RSSIs, and how many samples it rests on. Empty for a device
    /// first seen after the final poll.
    func median(for id: DeviceID) -> (value: Int, samples: Int)? {
        guard let rssis = entries[id]?.rssis, !rssis.isEmpty else { return nil }
        let sorted = rssis.sorted()
        return (sorted[sorted.count / 2], sorted.count)
    }
}
