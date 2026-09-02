import Testing
@testable import ThresholdDomain

@Suite("ObservationValidator (§1.1)")
struct ObservationValidatorTests {
    private let known: Set<DeviceID> = [DeviceID("device-A"), DeviceID("device-B")]
    private let skew = Duration.seconds(1)

    private func observation(_ rssi: Int, at ns: Int64, device: String = "device-A") -> BLEObservation {
        BLEObservation(device: DeviceID(device), at: MonotonicInstant(nanoseconds: ns), rssi: rssi)
    }

    @Test func acceptsInRangeSampleFromKnownDevice() {
        let result = ObservationValidator.validate(
            observation(-60, at: 1_000), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(result == .accepted)
        #expect(result.isAccepted)
        #expect(!result.clockAnomaly)
    }

    @Test(arguments: [-121, 1, 100, -200])
    func rejectsRSSIOutsideClosedRange(_ rssi: Int) {
        let result = ObservationValidator.validate(
            observation(rssi, at: 0), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(result == .rejected(.rssiOutOfRange))
    }

    @Test(arguments: [-120, 0, -60])
    func acceptsRSSIAtAndInsideBounds(_ rssi: Int) {
        let result = ObservationValidator.validate(
            observation(rssi, at: 0), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(result == .accepted)
    }

    @Test func rejectsUnknownDevice() {
        let result = ObservationValidator.validate(
            observation(-60, at: 0, device: "device-Z"), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(result == .rejected(.unknownDevice))
    }

    @Test func rangeCheckPrecedesRegistryCheck() {
        // Rule order matters for diagnostics: an out-of-range sample is reported as such
        // even when it also comes from an unregistered device.
        let result = ObservationValidator.validate(
            observation(-500, at: 0, device: "device-Z"), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(result == .rejected(.rssiOutOfRange))
    }

    @Test func acceptsReorderingWithinMaxSkew() {
        let last = MonotonicInstant(nanoseconds: 10_000_000_000)
        let result = ObservationValidator.validate(
            observation(-60, at: 9_500_000_000), lastAccepted: last, knownDevices: known, maxSkew: skew)
        #expect(result == .accepted)
    }

    @Test func acceptsExactlyAtSkewBoundary() {
        let last = MonotonicInstant(nanoseconds: 10_000_000_000)
        let result = ObservationValidator.validate(
            observation(-60, at: 9_000_000_000), lastAccepted: last, knownDevices: known, maxSkew: skew)
        #expect(result == .accepted)
    }

    @Test func rejectsOutOfOrderBeyondSkewAndFlagsClockAnomaly() {
        let last = MonotonicInstant(nanoseconds: 10_000_000_000)
        let result = ObservationValidator.validate(
            observation(-60, at: 8_999_999_999), lastAccepted: last, knownDevices: known, maxSkew: skew)
        #expect(result == .rejected(.outOfOrder))
        #expect(result.clockAnomaly)
        #expect(!result.isAccepted)
    }

    @Test func clockAnomalyIsFlaggedOnlyForOutOfOrder() {
        let range = ObservationValidator.validate(
            observation(5, at: 0), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        let unknown = ObservationValidator.validate(
            observation(-60, at: 0, device: "device-Z"), lastAccepted: nil, knownDevices: known, maxSkew: skew)
        #expect(!range.clockAnomaly)
        #expect(!unknown.clockAnomaly)
    }
}
