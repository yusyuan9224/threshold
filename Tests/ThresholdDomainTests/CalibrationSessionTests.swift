import Testing
@testable import ThresholdDomain

// docs/specs/proximity-domain.md 7.2
@Suite("CalibrationSession")
struct CalibrationSessionTests {

    // MARK: progress

    @Test func progressReportsCountAndElapsedPerPhase() {
        var s = CalibrationSession()
        CalFixture.feed(&s, CalFixture.cleanNear, phase: .near)           // 21 samples, 1 s apart
        CalFixture.feed(&s, Array(repeating: -75, count: 5), phase: .far) // 5 samples, 1 s apart

        let near = s.progress(for: .near)
        #expect(near.samples == 21)
        #expect(near.elapsed == .seconds(20))

        let far = s.progress(for: .far)
        #expect(far.samples == 5)
        #expect(far.elapsed == .seconds(4))
    }

    @Test func progressOnEmptyPhaseIsZero() {
        let s = CalibrationSession()
        #expect(s.progress(for: .near).samples == 0)
        #expect(s.progress(for: .near).elapsed == .zero)
    }

    @Test func progressWithASingleSampleHasZeroElapsed() {
        var s = CalibrationSession()
        s.add(-55, at: .zero + .seconds(9), phase: .near)
        #expect(s.progress(for: .near).samples == 1)
        #expect(s.progress(for: .near).elapsed == .zero)
    }

    @Test func elapsedSpansEarliestToLatestRegardlessOfArrivalOrder() {
        var s = CalibrationSession()
        s.add(-55, at: .zero + .seconds(30), phase: .near)
        s.add(-55, at: .zero + .seconds(5), phase: .near)
        #expect(s.progress(for: .near).elapsed == .seconds(25))
    }

    // MARK: success

    @Test func successProducesTheProfileFromTheSpecFormulas() throws {
        // 21 near / 21 far samples spanning exactly minDuration (20 s).
        let profile = try CalFixture.session().finish().get()
        // nearBaseline = median(near), farBaseline = median(far)
        #expect(profile.nearBaseline == -55)
        #expect(profile.farBaseline == -75)
        // noise = max(MAD near, MAD far)
        #expect(profile.noise == 1)
        // midpoint = (near + far) / 2
        #expect(profile.midpoint == -65)
        // slope = (near - far) / 4
        #expect(profile.slope == 5)
        #expect(profile == CalFixture.profile)
    }

    @Test func successNoiseTakesTheLargerOfTheTwoPhaseMADs() throws {
        // near MAD 1, far MAD 3 -> noise 3. Separation 20 >= max(8, 9).
        let far = CalFixture.block([-78, -75, -72], times: 7)
        let profile = try CalFixture.session(far: far).finish().get()
        #expect(profile.noise == 3)
        #expect(profile.farBaseline == -75)
    }

    @Test func exactlyMinimumSampleCountSucceeds() throws {
        let near = Array(repeating: -55, count: 15)
        let far = Array(repeating: -75, count: 15)
        let s = CalFixture.session(near: near, far: far, every: .seconds(2))
        #expect(s.progress(for: .near).samples == 15)
        let profile = try s.finish().get()
        #expect(profile.noise == 0)
        #expect(profile.nearBaseline == -55)
    }

    // MARK: insufficientSamples

    @Test func tooFewNearSamplesFail() {
        let near = Array(repeating: -55, count: 14)
        #expect(CalFixture.session(near: near).finish().failure == .insufficientSamples(phase: .near))
    }

    @Test func tooFewFarSamplesFail() {
        let far = Array(repeating: -75, count: 14)
        #expect(CalFixture.session(far: far).finish().failure == .insufficientSamples(phase: .far))
    }

    @Test func enoughSamplesButTooShortADurationFails() {
        // 21 samples at 500 ms -> 10 s span, under minDuration 20 s.
        #expect(CalFixture.session(every: .milliseconds(500)).finish().failure
                == .insufficientSamples(phase: .near))
    }

    @Test func emptySessionFailsOnNearFirst() {
        #expect(CalibrationSession().finish().failure == .insufficientSamples(phase: .near))
    }

    @Test func nearIsCheckedBeforeFar() {
        let short = Array(repeating: -60, count: 3)
        #expect(CalFixture.session(near: short, far: short).finish().failure
                == .insufficientSamples(phase: .near))
    }

    // MARK: tooNoisy

    @Test func nearPhaseAboveMaxNoiseFails() {
        // median -55, deviations 10/0/10 -> MAD 10 > 6
        let near = CalFixture.block([-65, -55, -45], times: 7)
        #expect(CalFixture.session(near: near).finish().failure == .tooNoisy(phase: .near))
    }

    @Test func farPhaseAboveMaxNoiseFails() {
        let far = CalFixture.block([-85, -75, -65], times: 7)
        #expect(CalFixture.session(far: far).finish().failure == .tooNoisy(phase: .far))
    }

    @Test func madExactlyAtMaxNoiseIsAccepted() throws {
        // MAD 6 is not > 6.
        let near = CalFixture.block([-61, -55, -49], times: 7)
        let profile = try CalFixture.session(near: near).finish().get()
        #expect(profile.noise == 6)
    }

    @Test func insufficientSamplesIsCheckedBeforeNoise() {
        // Noisy *and* short: the sample-count rule wins (spec order).
        let near = CalFixture.block([-65, -55, -45], times: 2) // 6 samples, MAD 10
        #expect(CalFixture.session(near: near).finish().failure == .insufficientSamples(phase: .near))
    }

    // MARK: overlap (T-04)

    @Test func t04_nearAndFarOverlapProducesOverlapAndNoProfile() {
        // medians -60 / -64 -> separation 4 < max(8, 3 * 0)
        let near = Array(repeating: -60, count: 21)
        let far = Array(repeating: -64, count: 21)
        let result = CalFixture.session(near: near, far: far).finish()
        #expect(result.failure == .overlap)
        #expect(result.profile == nil)   // no profile is produced
    }

    @Test func t04_separationBelowThreeTimesMADIsOverlapEvenAboveMinSeparation() {
        // medians -55 / -65 -> separation 10 >= minSeparationDB 8,
        // but MAD 4 on both phases -> 3 * 4 = 12 > 10 -> overlap.
        let near = CalFixture.block([-59, -55, -51], times: 7)
        let far = CalFixture.block([-69, -65, -61], times: 7)
        let result = CalFixture.session(near: near, far: far).finish()
        #expect(result.failure == .overlap)
        #expect(result.profile == nil)
    }

    @Test func separationExactlyAtTheThresholdIsAccepted() throws {
        // medians -55 / -63 -> separation 8 == max(8, 0); not < threshold.
        let near = Array(repeating: -55, count: 21)
        let far = Array(repeating: -63, count: 21)
        let profile = try CalFixture.session(near: near, far: far).finish().get()
        #expect(profile.nearBaseline == -55)
        #expect(profile.farBaseline == -63)
        #expect(profile.midpoint == -59)
        #expect(profile.slope == 2)
    }

    @Test func farStrongerThanNearIsOverlap() {
        // Negative separation: the user calibrated the two phases backwards.
        let near = Array(repeating: -80, count: 21)
        let far = Array(repeating: -55, count: 21)
        #expect(CalFixture.session(near: near, far: far).finish().failure == .overlap)
    }

    @Test func noiseIsCheckedBeforeOverlap() {
        // Overlapping medians AND a noisy near phase: noise wins (spec order).
        let near = CalFixture.block([-70, -60, -50], times: 7)  // median -60, MAD 10
        let far = Array(repeating: -64, count: 21)
        #expect(CalFixture.session(near: near, far: far).finish().failure == .tooNoisy(phase: .near))
    }

    // MARK: policy is honoured

    @Test func policyOverridesAreRespected() throws {
        var policy = CalibrationPolicy()
        policy.minSamples = 3
        policy.minDuration = .seconds(2)
        policy.minSeparationDB = 2
        var s = CalibrationSession(policy: policy)
        CalFixture.feed(&s, [-55, -55, -55], phase: .near)
        CalFixture.feed(&s, [-58, -58, -58], phase: .far)
        let profile = try s.finish().get()
        #expect(profile.nearBaseline == -55)
        #expect(profile.farBaseline == -58)
    }
}

// Readability helpers over `Result`, used only by these suites.
extension Result where Success == CalibrationProfile, Failure == CalibrationFailure {
    var failure: CalibrationFailure? {
        if case .failure(let f) = self { return f }
        return nil
    }
    var profile: CalibrationProfile? {
        if case .success(let p) = self { return p }
        return nil
    }
}
