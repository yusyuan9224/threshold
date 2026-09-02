import Foundation
import Testing
@testable import ThresholdDomain

/// Pins the wire contract between `Tools/rssi-record` and this decoder. These assertions are the
/// reason the recorder can change its internals freely: the file format is what is agreed, and it
/// is checked here rather than inferred from whatever `Codable` synthesises on either side.
@Suite("Fixture line format (rssi-record contract)")
struct FixtureFormatTests {
    private func line(_ json: String) throws -> EngineInput? {
        try JSONDecoder().decode(FixtureLine.self, from: Data(json.utf8)).engineInput()
    }

    @Test func observationLine() throws {
        let input = try line(#"{"kind":"observation","t":75,"device":"device-A","rssi":-54}"#)
        #expect(input == .observation(BLEObservation(
            device: DeviceID("device-A"),
            at: MonotonicInstant(nanoseconds: 75_000_000),
            rssi: -54
        )))
    }

    @Test(arguments: [
        ("available", SensorStatus.available),
        ("degraded.resetting", .degraded(.resetting)),
        ("degraded.scanInterrupted", .degraded(.scanInterrupted)),
        ("unavailable.poweredOff", .unavailable(.poweredOff)),
        ("unavailable.unauthorized", .unavailable(.unauthorized)),
        ("unavailable.unsupported", .unavailable(.unsupported)),
        ("unavailable.scannerFailed", .unavailable(.scannerFailed)),
    ])
    func everySensorSpelling(_ spelling: String, _ expected: SensorStatus) throws {
        let input = try line(#"{"kind":"sensor","t":840112,"status":"\#(spelling)"}"#)
        #expect(input == .sensor(expected, at: MonotonicInstant(nanoseconds: 840_112_000_000)))
    }

    @Test func tickAndResetLines() throws {
        #expect(try line(#"{"kind":"tick","t":26000}"#) == .tick(at: MonotonicInstant(nanoseconds: 26_000_000_000)))
        #expect(try line(#"{"kind":"reset","t":12000,"reason":"systemWake"}"#)
                == .reset(.systemWake, at: MonotonicInstant(nanoseconds: 12_000_000_000)))
    }

    @Test func summaryLineIsSkippedRatherThanRejected() throws {
        let summary = #"""
        {"kind":"summary","durationMs":1200431,"windowMs":10000,"sensorEvents":3,"devices":[{"device":"device-A","samples":1142,"droppedInvalidRSSI":5,"windows":121,"windowsWithSamples":121,"receivingRatio":1.0000,"longestGapMs":1206,"medianRSSI":-57,"madRSSI":4}]}
        """#
        #expect(try line(summary) == nil)
    }

    @Test func metadataWithRecorderExtrasStillDecodes() throws {
        // The recorder adds durationMs; unknown meta fields must not break the decoder.
        let json = #"""
        {"kind":"meta","macClass":"laptop","deviceClass":"iphone","scenario":"desk-1m","recorder":"rssi-record 0.1","anonymized":true,"durationMs":1200431}
        """#
        let meta = try JSONDecoder().decode(FixtureMeta.self, from: Data(json.utf8))
        #expect(meta.scenario == "desk-1m")
        #expect(meta.anonymized)
        #expect(meta.profile == nil, "a recording without a calibration profile replays against the default")
    }

    @Test func unknownSpellingsAreRejectedLoudly() {
        #expect(throws: FixtureError.self) { try line(#"{"kind":"sensor","t":0,"status":"degraded"}"#) }
        #expect(throws: FixtureError.self) { try line(#"{"kind":"sensor","t":0,"status":"off"}"#) }
        #expect(throws: FixtureError.self) { try line(#"{"kind":"nonsense","t":0}"#) }
        #expect(throws: FixtureError.self) { try line(#"{"kind":"observation","t":0,"device":"device-A"}"#) }
    }

    /// CoreBluetooth's "value unavailable" sentinel is dropped at record time, but the Domain
    /// would reject it anyway. Both layers, because neither should be the only one.
    @Test func rssiSentinelWouldBeRejectedByTheValidator() {
        let result = ObservationValidator.validate(
            BLEObservation(device: DeviceID("device-A"), at: .zero, rssi: 127),
            lastAccepted: nil,
            knownDevices: [DeviceID("device-A")],
            maxSkew: .seconds(1)
        )
        #expect(result == .rejected(.rssiOutOfRange))
    }
}
