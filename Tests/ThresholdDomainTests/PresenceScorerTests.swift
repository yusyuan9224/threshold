import Testing
@testable import ThresholdDomain

private func at(_ seconds: Double) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: Int64(seconds * 1_000_000_000))
}

private func estimate(_ smoothed: Double, samples: Int = 5, lastSeen: Double = 0) -> SignalEstimate {
    SignalEstimate(smoothedRSSI: smoothed, sampleCount: samples, lastSeen: at(lastSeen), spread: 1)
}

@Suite("Math (stdlib-only exp/logistic)")
struct MathTests {
    @Test func expMatchesKnownValues() {
        #expect(abs(Math.exp(0) - 1) < 1e-15)
        #expect(abs(Math.exp(1) - 2.718281828459045) < 1e-12)
        #expect(abs(Math.exp(-1) - 0.36787944117144233) < 1e-12)
        #expect(abs(Math.exp(10) - 22026.465794806718) < 1e-8)
        #expect(abs(Math.exp(-10) - 0.00004539992976248485) < 1e-15)
    }

    @Test func expIsMonotonicAndFiniteAtExtremes() {
        #expect(Math.exp(-10_000) == 0)
        #expect(Math.exp(10_000).isFinite)
        #expect(Math.exp(2) > Math.exp(1.999))
    }

    @Test func logisticIsCentredAndSymmetric() {
        #expect(Math.logistic(0) == 0.5)
        #expect(abs(Math.logistic(-2) - (1 - Math.logistic(2))) < 1e-15)
        #expect(abs(Math.logistic(1) - 0.7310585786300049) < 1e-12)
    }

    @Test func logisticSaturatesWithoutOverflow() {
        #expect(Math.logistic(1_000) == 1)
        #expect(Math.logistic(-1_000) == 0)
        #expect((0.0...1.0).contains(Math.logistic(-800)))
    }
}

@Suite("PresenceScorer (§3.1)")
struct PresenceScorerTests {
    private let scorer = PresenceScorer(configuration: EngineConfiguration())
    private let profile = CalibrationProfile(nearBaseline: -55, farBaseline: -85, noise: 4, midpoint: -70, slope: 6)

    @Test func distanceIsAHalfAtTheCalibratedMidpoint() {
        let score = scorer.score(for: estimate(-70), now: at(0), profile: profile)
        #expect(score.distance == 0.5)
    }

    @Test func distanceRisesTowardOneAsSignalStrengthens() {
        let near = scorer.score(for: estimate(-55), now: at(0), profile: profile).distance
        let far = scorer.score(for: estimate(-85), now: at(0), profile: profile).distance
        #expect(near > 0.9)
        #expect(far < 0.1)
        #expect(abs(near - (1 - far)) < 1e-12, "logistic is symmetric about the midpoint")
    }

    @Test func slopeControlsHowSharplyDistanceChanges() {
        let steep = CalibrationProfile(nearBaseline: -55, farBaseline: -85, noise: 4, midpoint: -70, slope: 2)
        let gentle = CalibrationProfile(nearBaseline: -55, farBaseline: -85, noise: 4, midpoint: -70, slope: 12)
        let steepScore = scorer.score(for: estimate(-64), now: at(0), profile: steep).distance
        let gentleScore = scorer.score(for: estimate(-64), now: at(0), profile: gentle).distance
        #expect(steepScore > gentleScore)
    }

    @Test func recencyIsFullWithinTheGraceWindow() {
        #expect(scorer.score(for: estimate(-60, lastSeen: 0), now: at(0), profile: profile).recency == 1)
        #expect(scorer.score(for: estimate(-60, lastSeen: 0), now: at(2), profile: profile).recency == 1)
    }

    @Test func recencyDecaysLinearlyToZeroAtTheSilentThreshold() {
        // full until 2 s, zero at 10 s → 6 s of age is exactly halfway.
        #expect(abs(scorer.score(for: estimate(-60), now: at(6), profile: profile).recency - 0.5) < 1e-12)
        #expect(abs(scorer.score(for: estimate(-60), now: at(4), profile: profile).recency - 0.75) < 1e-12)
        #expect(scorer.score(for: estimate(-60), now: at(10), profile: profile).recency == 0)
        #expect(scorer.score(for: estimate(-60), now: at(30), profile: profile).recency == 0)
    }

    @Test func recencyNeverGoesNegativeOnEarlyTimestamps() {
        #expect(scorer.score(for: estimate(-60, lastSeen: 5), now: at(0), profile: profile).recency == 1)
    }

    @Test func sufficiencyScalesWithSampleCountAndSaturatesAtMinSamples() {
        #expect(scorer.score(for: estimate(-60, samples: 1), now: at(0), profile: profile).sufficiency == 0.2)
        #expect(scorer.score(for: estimate(-60, samples: 4), now: at(0), profile: profile).sufficiency == 0.8)
        #expect(scorer.score(for: estimate(-60, samples: 5), now: at(0), profile: profile).sufficiency == 1)
        #expect(scorer.score(for: estimate(-60, samples: 20), now: at(0), profile: profile).sufficiency == 1)
    }

    @Test func valueIsTheProductOfTheThreeFactors() {
        let score = scorer.score(for: estimate(-60, samples: 3), now: at(4), profile: profile)
        #expect(abs(score.value - score.distance * score.recency * score.sufficiency) < 1e-15)
        #expect((0.0...1.0).contains(score.value))
    }

    @Test func aStrongButUndersampledSignalCannotReachTheEnterThreshold() {
        // Sufficiency is the guard that makes "wake within 3 s" impossible after a reset.
        let score = scorer.score(for: estimate(-40, samples: 2), now: at(0), profile: profile)
        #expect(score.distance > 0.99)
        #expect(score.value < EngineConfiguration().enterThreshold)
    }
}

@Suite("AnyDeviceFusion (§3.4)")
struct AnyDeviceFusionTests {
    private let fusion = AnyDeviceFusion()

    private func track(_ name: String, value: Double?, receiving: Bool) -> DeviceTrack {
        let score = value.map { PresenceScore(distance: $0, recency: 1, sufficiency: 1) }
        return DeviceTrack(
            device: DeviceID(name),
            observation: receiving ? .receiving : .silent(since: at(0)),
            estimate: estimate(-60),
            score: score,
            isCalibrated: true
        )
    }

    @Test func returnsNilWhenNoDeviceIsReceiving() {
        #expect(fusion.fuse([]) == nil)
        #expect(fusion.fuse([track("device-A", value: 0.9, receiving: false)]) == nil)
    }

    @Test func returnsNilWhenReceivingDevicesHaveNoScore() {
        #expect(fusion.fuse([track("device-A", value: nil, receiving: true)]) == nil)
    }

    @Test func takesTheMaximumOverReceivingDevices() {
        let fused = fusion.fuse([
            track("device-A", value: 0.4, receiving: true),
            track("device-B", value: 0.85, receiving: true),
        ])
        #expect(fused == 0.85)
    }

    @Test func silentDevicesAreIgnoredEvenWhenTheirLastScoreWasHigh() {
        // The mechanism that separates silence from absence: a silent device contributes nothing,
        // rather than contributing a stale high score or a misleading zero.
        let fused = fusion.fuse([
            track("device-A", value: 0.95, receiving: false),
            track("device-B", value: 0.2, receiving: true),
        ])
        #expect(fused == 0.2)
    }
}
