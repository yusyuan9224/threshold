import ThresholdDomain

/// One line of the fixture, in the order it will be written.
enum RecordedEvent {
    case observation(t: Int64, device: Int, rssi: Int)
    case sensor(t: Int64, status: String)

    var t: Int64 {
        switch self {
        case .observation(let t, _, _): t
        case .sensor(let t, _): t
        }
    }
}

/// The metrics SPIKE-009 §C asks for, per device, with **no identifier and no name**.
struct DeviceMetrics {
    let alias: String
    let samples: Int
    let droppedInvalidRSSI: Int
    let windows: Int
    let windowsWithSamples: Int
    let longestGapMs: Int64
    /// Lower median (`sorted[count / 2]`), matching the convention already used in
    /// the SPIKE-009 evidence tables.
    let medianRSSI: Int
    /// Median absolute deviation from the median, in dB. Also a lower median, so it
    /// is integral.
    let madRSSI: Int

    var receivingRatio: Double {
        windows == 0 ? 0 : Double(windowsWithSamples) / Double(windows)
    }
}

/// Collects every recorded event and derives the summary.
///
/// An actor because two independent `AsyncStream` consumers (observations and sensor
/// states) feed it concurrently. Events are buffered rather than streamed to disk so
/// the file can be written in non-decreasing `t` order: the two channels are stamped
/// from one clock but delivered on two tasks, so arrival order is not time order.
/// A worst-case field run (30 min, several devices, ~1 sample/s each) is a few
/// thousand events, so buffering costs nothing worth optimising.
actor Recording {
    /// Length of a receiving-ratio window (SPIKE-009 §C: "receiving 比例（每 10 s
    /// 視窗內有樣本的比例）").
    static let windowMs: Int64 = 10_000

    private let aliasIndex: [DeviceID: Int]
    private let aliases: [String]
    private let t0: MonotonicInstant

    private var events: [RecordedEvent] = []
    private var dropped: [Int]
    private var sampleTimes: [[Int64]]
    private var rssis: [[Int]]

    init(devices: [DeviceID], t0: MonotonicInstant) {
        self.t0 = t0
        self.aliases = devices.indices.map(Self.alias(at:))
        self.aliasIndex = Dictionary(
            uniqueKeysWithValues: zip(devices, devices.indices)
        )
        self.dropped = Array(repeating: 0, count: devices.count)
        self.sampleTimes = Array(repeating: [], count: devices.count)
        self.rssis = Array(repeating: [], count: devices.count)
    }

    /// `device-A`, `device-B`, ... — the anonymised `DeviceID` testing.md §3 requires.
    static func alias(at index: Int) -> String {
        "device-\(String(UnicodeScalar(UInt8(65 + index))))"
    }

    var sensorEventCount: Int {
        events.reduce(0) { count, event in
            if case .sensor = event { count + 1 } else { count }
        }
    }

    func add(_ observation: BLEObservation) {
        guard let index = aliasIndex[observation.device] else { return }
        let t = milliseconds(since: observation.at)
        // 127 is CoreBluetooth's "RSSI unavailable" sentinel, not a reading. It is
        // dropped rather than clamped — a fixture carrying +127 dBm would poison the
        // signal pipeline — and counted so the summary shows how often it happened.
        guard observation.rssi != 127 else {
            dropped[index] += 1
            return
        }
        events.append(.observation(t: t, device: index, rssi: observation.rssi))
        sampleTimes[index].append(t)
        rssis[index].append(observation.rssi)
    }

    func add(_ status: Timestamped<SensorStatus>) {
        events.append(.sensor(t: milliseconds(since: status.at), status: status.value.fixtureName))
    }

    /// Receiving ratio per alias over the elapsed time so far, for the 10 s stderr tick.
    func progress(elapsedMs: Int64) -> [(alias: String, ratio: Double, samples: Int)] {
        aliases.indices.map { index in
            let metrics = metrics(for: index, durationMs: elapsedMs)
            return (metrics.alias, metrics.receivingRatio, metrics.samples)
        }
    }

    /// The fixture body: every event, in non-decreasing `t`.
    ///
    /// `sort(by:)` is not stable in the stdlib, so the sequence number breaks ties by
    /// insertion order and keeps two events stamped in the same millisecond from
    /// swapping places between runs.
    func lines() -> [String] {
        events.enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map { Self.line(for: $0.element) }
    }

    func summary(durationMs: Int64) -> [DeviceMetrics] {
        aliases.indices.map { metrics(for: $0, durationMs: durationMs) }
    }

    // MARK: - Metrics

    private func metrics(for index: Int, durationMs: Int64) -> DeviceMetrics {
        let times = sampleTimes[index]
        let windows = Int((max(durationMs, 0) + Self.windowMs - 1) / Self.windowMs)
        let occupied = Set(times.map { $0 / Self.windowMs })
        // Windows are counted against the run length, so a window index beyond the
        // nominal duration (a sample that landed during teardown) cannot push the
        // ratio above 1.
        let windowsWithSamples = occupied.filter { $0 < Int64(windows) }.count

        let sorted = rssis[index].sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let deviations = sorted.map { abs($0 - median) }.sorted()
        let mad = deviations.isEmpty ? 0 : deviations[deviations.count / 2]

        return DeviceMetrics(
            alias: aliases[index],
            samples: times.count,
            droppedInvalidRSSI: dropped[index],
            windows: windows,
            windowsWithSamples: windowsWithSamples,
            longestGapMs: Self.longestGap(times: times, durationMs: durationMs),
            medianRSSI: median,
            madRSSI: mad
        )
    }

    /// Longest silent stretch, **including the head and tail of the run**: a device
    /// that was not seen for the first four minutes was silent for four minutes, and
    /// SPIKE-009's ≤ 10 s success criterion has to be judged against that.
    /// With no samples at all the gap is the whole run.
    static func longestGap(times: [Int64], durationMs: Int64) -> Int64 {
        guard let first = times.first, let last = times.last else { return max(durationMs, 0) }
        var longest = max(first, 0)
        for (previous, next) in zip(times, times.dropFirst()) {
            longest = max(longest, next - previous)
        }
        return max(longest, durationMs - last)
    }

    private func milliseconds(since instant: MonotonicInstant) -> Int64 {
        (instant - t0).wholeNanoseconds / 1_000_000
    }

    private static func line(for event: RecordedEvent) -> String {
        switch event {
        case .observation(let t, let device, let rssi):
            JSONLine.object([
                ("kind", JSONLine.str("observation")),
                ("t", JSONLine.int(t)),
                ("device", JSONLine.str(alias(at: device))),
                ("rssi", JSONLine.int(rssi)),
            ])
        case .sensor(let t, let status):
            JSONLine.object([
                ("kind", JSONLine.str("sensor")),
                ("t", JSONLine.int(t)),
                ("status", JSONLine.str(status)),
            ])
        }
    }
}
