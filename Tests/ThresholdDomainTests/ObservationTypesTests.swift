import Testing
@testable import ThresholdDomain

@Suite("Observation types")
struct ObservationTypesTests {
    @Test func bleObservationDefaultsToAdvertisement() {
        let o = BLEObservation(device: DeviceID("device-A"), at: .zero, rssi: -60)
        #expect(o.source == .advertisement)
        #expect(o.device.raw == "device-A")
    }

    @Test func sensorStatusIsEquatableAcrossReasons() {
        #expect(SensorStatus.unavailable(.poweredOff) != SensorStatus.unavailable(.unauthorized))
        #expect(SensorStatus.degraded(.resetting) == SensorStatus.degraded(.resetting))
    }
}
