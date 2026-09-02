import Foundation
import Testing
@testable import ThresholdDomain

@Suite("CalibrationPolicy")
struct CalibrationPolicyTests {
    // docs/specs/proximity-domain.md 7.4 - Initial Tunable Defaults.
    @Test func defaultsMatchSpec() {
        let p = CalibrationPolicy()
        #expect(p.maxProfileAge == nil)          // age-based revalidation disabled for MVP
        #expect(p.driftSuspectThresholdDB == 8)
        #expect(p.driftWindow == .seconds(1800))
        #expect(p.autoDisarmOnDrift == false)
        #expect(p.driftDisarmThresholdDB == 15)
    }

    // 7.2 session parameters.
    @Test func sessionDefaultsMatchSpec() {
        let p = CalibrationPolicy()
        #expect(p.minDuration == .seconds(20))
        #expect(p.minSamples == 15)
        #expect(p.maxNoiseDB == 6)
        #expect(p.minSeparationDB == 8)
        #expect(p.revalidationToleranceDB == 6)
    }

    @Test func roundTripsThroughCodable() throws {
        var p = CalibrationPolicy()
        p.maxProfileAge = .seconds(86_400)
        p.autoDisarmOnDrift = true
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(CalibrationPolicy.self, from: data) == p)
    }

    @Test func nilMaxProfileAgeRoundTrips() throws {
        let p = CalibrationPolicy()
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(CalibrationPolicy.self, from: data)
        #expect(decoded == p)
        #expect(decoded.maxProfileAge == nil)
    }
}

@Suite("CalibrationStats")
struct CalibrationStatsTests {
    @Test func medianOfOddCountIsMiddleElement() {
        #expect(CalibrationStats.median([3, 1, 2]) == 2)
    }

    @Test func medianOfEvenCountAveragesTheTwoMiddleElements() {
        #expect(CalibrationStats.median([1, 2, 3, 4]) == 2.5)
    }

    @Test func medianOfEmptyIsNil() {
        #expect(CalibrationStats.median([]) == nil)
    }

    @Test func medianAbsoluteDeviationIsMedianOfAbsoluteDeviations() {
        // median = -55; deviations = 1,0,1 repeated 7x -> MAD = 1
        #expect(CalibrationStats.medianAbsoluteDeviation(CalFixture.cleanNear.map(Double.init)) == 1)
    }

    @Test func madOfConstantSeriesIsZero() {
        #expect(CalibrationStats.medianAbsoluteDeviation([-60, -60, -60]) == 0)
    }

    @Test func madOfEmptyIsNil() {
        #expect(CalibrationStats.medianAbsoluteDeviation([]) == nil)
    }
}

@Suite("CalibrationRecord persistence")
struct CalibrationRecordCodableTests {
    @Test func roundTripsThroughCodable() throws {
        let record = CalFixture.record()
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(CalibrationRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.profile == CalFixture.profile)
        #expect(decoded.createdAtUnixSeconds == 1_000_000)
    }

    @Test func encodedFormCarriesNoMonotonicTime() throws {
        // 7.1: the persistence unit must not contain a MonotonicInstant.
        let data = try JSONEncoder().encode(CalFixture.record())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("nanoseconds"))
    }
}
