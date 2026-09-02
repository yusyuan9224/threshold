import Testing
@testable import ThresholdDomain

private let thisDevice = DeviceID("device-A")
private let thisMac = "mac-1"
private let thisOS = 26

private func gate(
    _ record: CalibrationRecord?,
    device: DeviceID = thisDevice,
    macIdentity: String = thisMac,
    osMajorVersion: Int = thisOS,
    nowUnixSeconds: Int64 = 1_000_100,
    policy: CalibrationPolicy = CalibrationPolicy()
) -> CalibrationGate {
    CalibrationValidator.gate(
        record: record,
        device: device,
        macIdentity: macIdentity,
        osMajorVersion: osMajorVersion,
        nowUnixSeconds: nowUnixSeconds,
        policy: policy
    )
}

// docs/specs/proximity-domain.md 7.3; testing.md T-17 (gate half)
@Suite("CalibrationValidator.gate")
struct CalibrationValidatorGateTests {

    @Test func matchingRecordArms() {
        #expect(gate(CalFixture.record()) == .armed(CalFixture.profile))
    }

    @Test func missingRecordIsNoProfile() {
        #expect(gate(nil) == .notArmed(.noProfile))
    }

    // T-17
    @Test func t17_deviceMismatchIsNotArmed() {
        let record = CalFixture.record(device: DeviceID("device-B"))
        #expect(gate(record) == .notArmed(.deviceMismatch))
    }

    // T-17
    @Test func t17_macMismatchIsNotArmed() {
        let record = CalFixture.record(macIdentity: "mac-2")
        #expect(gate(record) == .notArmed(.macMismatch))
    }

    // T-17
    @Test func t17_osMajorChangeNeedsRevalidation() {
        let record = CalFixture.record(osMajorVersion: 25)
        #expect(gate(record) == .notArmed(.needsRevalidation(osMajorChanged: true)))
    }

    // T-17: maxProfileAge is nil for MVP, so an ancient record still arms.
    @Test func t17_ageIsIgnoredWhenMaxProfileAgeIsNil() {
        let record = CalFixture.record(createdAtUnixSeconds: 0)
        #expect(CalibrationPolicy().maxProfileAge == nil)
        #expect(gate(record, nowUnixSeconds: 4_000_000_000) == .armed(CalFixture.profile))
    }

    // T-17: with age enabled, an over-age record needs revalidation without an OS change.
    @Test func t17_overAgeRecordNeedsRevalidationWithoutOSChange() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(86_400)
        let record = CalFixture.record(createdAtUnixSeconds: 1_000_000)
        let g = gate(record, nowUnixSeconds: 1_000_000 + 86_401, policy: policy)
        #expect(g == .notArmed(.needsRevalidation(osMajorChanged: false)))
    }

    @Test func recordExactlyAtMaxProfileAgeStillArms() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(86_400)
        let record = CalFixture.record(createdAtUnixSeconds: 1_000_000)
        #expect(gate(record, nowUnixSeconds: 1_000_000 + 86_400, policy: policy) == .armed(CalFixture.profile))
    }

    @Test func recordCreatedInTheFutureIsNotTreatedAsExpired() {
        // Wall-clock skew must not silently disarm.
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(86_400)
        let record = CalFixture.record(createdAtUnixSeconds: 2_000_000)
        #expect(gate(record, nowUnixSeconds: 1_000_000, policy: policy) == .armed(CalFixture.profile))
    }

    // MARK: precedence (7.3 lists the checks in order)

    @Test func deviceMismatchOutranksMacAndOSAndAge() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(1)
        let record = CalFixture.record(
            device: DeviceID("device-B"), macIdentity: "mac-2", osMajorVersion: 25, createdAtUnixSeconds: 0
        )
        #expect(gate(record, nowUnixSeconds: 4_000_000_000, policy: policy) == .notArmed(.deviceMismatch))
    }

    @Test func macMismatchOutranksOSAndAge() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(1)
        let record = CalFixture.record(macIdentity: "mac-2", osMajorVersion: 25, createdAtUnixSeconds: 0)
        #expect(gate(record, nowUnixSeconds: 4_000_000_000, policy: policy) == .notArmed(.macMismatch))
    }

    @Test func osChangeOutranksAge() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(1)
        let record = CalFixture.record(osMajorVersion: 25, createdAtUnixSeconds: 0)
        let g = gate(record, nowUnixSeconds: 4_000_000_000, policy: policy)
        #expect(g == .notArmed(.needsRevalidation(osMajorChanged: true)))
    }

    // MARK: the display-only default must never arm (7.1 / ADR-003 #6)

    @Test func defaultProfileNeverAppearsInsideArmed() {
        var policy = CalibrationPolicy()
        policy.maxProfileAge = .seconds(1)
        // Every gate input shape, including a record whose stored profile *is* the default.
        let records: [CalibrationRecord?] = [
            nil,
            CalFixture.record(),
            CalFixture.record(device: DeviceID("device-B")),
            CalFixture.record(macIdentity: "mac-2"),
            CalFixture.record(osMajorVersion: 25),
            CalFixture.record(createdAtUnixSeconds: 0),
            CalFixture.record(profile: .default),
            CalFixture.record(profile: .default, osMajorVersion: 25),
        ]
        for record in records {
            for now: Int64 in [1_000_100, 4_000_000_000] {
                for p in [CalibrationPolicy(), policy] {
                    let g = gate(record, nowUnixSeconds: now, policy: p)
                    if case .armed(let armedProfile) = g {
                        // The only way `.default` could arm is if it were stored as a real profile,
                        // which the validator must refuse.
                        #expect(armedProfile != .default)
                    }
                }
            }
        }
    }

    @Test func aRecordStoringTheDisplayOnlyDefaultDoesNotArm() {
        // `CalibrationProfile.default` documents itself as display-only and states it never
        // appears inside `.armed`. A persisted record holding it is not a real profile.
        let g = gate(CalFixture.record(profile: .default))
        #expect(!g.isArmed)
        #expect(g == .notArmed(.noProfile))
    }

    @Test func notArmedStillOffersTheDefaultProfileForScoring() {
        #expect(gate(nil).profileForScoring == .default)
        #expect(gate(nil).isArmed == false)
    }
}

// 7.3 Revalidation
@Suite("CalibrationValidator.revalidate")
struct CalibrationValidatorRevalidateTests {
    private let record = CalFixture.record()   // nearBaseline -55, noise 1 -> tolerance max(6, 2) = 6

    @Test func nearMedianInsideToleranceRearmsWithTheOriginalProfile() {
        let samples = Array(repeating: -58, count: 20)
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: samples, policy: CalibrationPolicy())
                == .rearmed(CalFixture.profile))
    }

    @Test func nearMedianOutsideToleranceRequiresFullCalibration() {
        let samples = Array(repeating: -40, count: 20)
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: samples, policy: CalibrationPolicy())
                == .requiresFullCalibration)
    }

    @Test func toleranceBoundaryIsInclusive() {
        // |median - nearBaseline| == 6 is still inside.
        let low = Array(repeating: -61, count: 20)
        let high = Array(repeating: -49, count: 20)
        let policy = CalibrationPolicy()
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: low, policy: policy)
                == .rearmed(CalFixture.profile))
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: high, policy: policy)
                == .rearmed(CalFixture.profile))
    }

    @Test func justOutsideTheBoundaryRequiresFullCalibration() {
        let samples = Array(repeating: -62, count: 20)
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: samples, policy: CalibrationPolicy())
                == .requiresFullCalibration)
    }

    @Test func toleranceWidensWithTwiceTheRecordedNoise() {
        // noise 5 -> tolerance max(6, 10) = 10; a 9 dB shift is still inside.
        let noisy = CalFixture.record(profile: CalibrationProfile(
            nearBaseline: -55, farBaseline: -75, noise: 5, midpoint: -65, slope: 5))
        let samples = Array(repeating: -64, count: 20)
        #expect(CalibrationValidator.revalidate(record: noisy, nearSamples: samples, policy: CalibrationPolicy())
                == .rearmed(noisy.profile))
    }

    @Test func tooFewSamplesRequiresFullCalibration() {
        // Under minSamples the median is not trustworthy enough to re-arm.
        let samples = Array(repeating: -55, count: 14)
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: samples, policy: CalibrationPolicy())
                == .requiresFullCalibration)
    }

    @Test func noSamplesRequiresFullCalibration() {
        #expect(CalibrationValidator.revalidate(record: record, nearSamples: [], policy: CalibrationPolicy())
                == .requiresFullCalibration)
    }

    @Test func rearmNeverYieldsTheDefaultProfile() {
        let result = CalibrationValidator.revalidate(
            record: record, nearSamples: Array(repeating: -55, count: 20), policy: CalibrationPolicy())
        if case .rearmed(let p) = result { #expect(p != .default) }
    }
}
