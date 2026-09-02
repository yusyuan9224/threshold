import Testing
@testable import ThresholdDomain

// Shared builders for the Calibration suites. Deterministic by construction:
// every sample carries an explicit `MonotonicInstant`, never a clock reading.
enum CalFixture {
    /// `block([-56, -55, -54], times: 7)` -> 21 samples, seven of each.
    static func block(_ values: [Int], times: Int) -> [Int] {
        values.flatMap { Array(repeating: $0, count: times) }
    }

    /// Feeds `values` into `session` on `phase`, one sample every `every`, starting at `startingAt`.
    static func feed(
        _ session: inout CalibrationSession,
        _ values: [Int],
        phase: CalibrationPhase,
        startingAt: MonotonicInstant = .zero,
        every: Duration = .seconds(1)
    ) {
        for (index, rssi) in values.enumerated() {
            session.add(rssi, at: startingAt + (every * index), phase: phase)
        }
    }

    /// 21 samples, median -55, MAD 1.
    static let cleanNear = block([-56, -55, -54], times: 7)
    /// 21 samples, median -75, MAD 1.
    static let cleanFar = block([-76, -75, -74], times: 7)

    /// The profile `cleanNear` + `cleanFar` must produce.
    static let profile = CalibrationProfile(
        nearBaseline: -55, farBaseline: -75, noise: 1, midpoint: -65, slope: 5
    )

    static func session(
        near: [Int] = cleanNear,
        far: [Int] = cleanFar,
        every: Duration = .seconds(1),
        policy: CalibrationPolicy = CalibrationPolicy()
    ) -> CalibrationSession {
        var s = CalibrationSession(policy: policy)
        feed(&s, near, phase: .near, every: every)
        feed(&s, far, phase: .far, every: every)
        return s
    }

    static func record(
        device: DeviceID = DeviceID("device-A"),
        macIdentity: String = "mac-1",
        profile: CalibrationProfile = CalFixture.profile,
        osMajorVersion: Int = 26,
        appVersion: String = "0.1.0",
        createdAtUnixSeconds: Int64 = 1_000_000
    ) -> CalibrationRecord {
        CalibrationRecord(
            device: device,
            macIdentity: macIdentity,
            profile: profile,
            osMajorVersion: osMajorVersion,
            appVersion: appVersion,
            createdAtUnixSeconds: createdAtUnixSeconds
        )
    }

    /// `count` samples of `value`, spaced so the series spans exactly `span`.
    static func driftSamples(
        value: Double,
        count: Int,
        span: Duration
    ) -> [(smoothedRSSI: Double, at: MonotonicInstant)] {
        precondition(count > 1)
        let step = span / (count - 1)
        return (0..<count).map { (smoothedRSSI: value, at: MonotonicInstant.zero + (step * $0)) }
    }
}
