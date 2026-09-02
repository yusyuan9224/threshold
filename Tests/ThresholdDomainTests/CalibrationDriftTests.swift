import Testing
@testable import ThresholdDomain

// docs/specs/proximity-domain.md 7.5
// Samples are supplied by the caller only under strong at-desk evidence
// (present + unlocked + inputIdle < 30 s); the detector itself is pure.
@Suite("DriftDetector")
struct DriftDetectorTests {
    private let record = CalFixture.record()      // nearBaseline -55
    private let detector = DriftDetector()
    private let policy = CalibrationPolicy()      // suspect 8, disarm 15, window 1800 s

    // MARK: assessment

    @Test func stableSignalOverAFullWindowIsNoDrift() {
        let samples = CalFixture.driftSamples(value: -56, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .none)
    }

    @Test func deviationAboveSuspectThresholdIsSuspected() {
        // |median(-65) - (-55)| = 10 > 8, and not yet > 15.
        let samples = CalFixture.driftSamples(value: -65, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .suspected(deviationDB: 10))
    }

    @Test func deviationAboveDisarmThresholdIsExceeded() {
        // |median(-75) - (-55)| = 20 > 15
        let samples = CalFixture.driftSamples(value: -75, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .exceeded(deviationDB: 20))
    }

    @Test func driftInTheStrongerDirectionCountsToo() {
        // Absolute deviation: the baseline moving up is drift as much as moving down.
        let samples = CalFixture.driftSamples(value: -45, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .suspected(deviationDB: 10))
    }

    @Test func deviationExactlyAtTheSuspectThresholdIsNotDrift() {
        // 8 is not > 8.
        let samples = CalFixture.driftSamples(value: -63, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .none)
    }

    @Test func deviationExactlyAtTheDisarmThresholdIsOnlySuspected() {
        // 15 is not > 15.
        let samples = CalFixture.driftSamples(value: -70, count: 61, span: .seconds(1800))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .suspected(deviationDB: 15))
    }

    // MARK: the window must actually be covered

    @Test func aShortSeriesIsNeverDriftHoweverLargeTheDeviation() {
        // Only 10 minutes of evidence: not sustained over the 30-minute window.
        let samples = CalFixture.driftSamples(value: -85, count: 21, span: .seconds(600))
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .none)
    }

    @Test func emptySamplesAreNoDrift() {
        #expect(detector.assess(record: record, samples: [], policy: policy) == .none)
    }

    @Test func aSingleSampleIsNoDrift() {
        let samples = [(smoothedRSSI: -90.0, at: MonotonicInstant.zero)]
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .none)
    }

    @Test func onlyTheMostRecentWindowIsMeasured() {
        // 60 minutes of history: the first half sits on baseline, the second half has drifted.
        // The rolling window must see only the drifted half.
        var samples = CalFixture.driftSamples(value: -55, count: 61, span: .seconds(1800))
        samples += (1...60).map {
            (smoothedRSSI: -75.0, at: MonotonicInstant.zero + .seconds(1800 + 30 * $0))
        }
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .exceeded(deviationDB: 20))
    }

    @Test func aBriefExcursionInsideTheWindowDoesNotTripTheMedian() {
        // Two minutes of a bad reading inside 30 minutes of good ones: the median absorbs it.
        var samples = CalFixture.driftSamples(value: -55, count: 57, span: .seconds(1680))
        samples += (1...4).map {
            (smoothedRSSI: -95.0, at: MonotonicInstant.zero + .seconds(1680 + 30 * $0))
        }
        #expect(detector.assess(record: record, samples: samples, policy: policy) == .none)
    }

    @Test func policyThresholdsAreHonoured() {
        var tight = CalibrationPolicy()
        tight.driftSuspectThresholdDB = 2
        tight.driftDisarmThresholdDB = 4
        tight.driftWindow = .seconds(60)
        let samples = CalFixture.driftSamples(value: -60, count: 5, span: .seconds(60))
        #expect(detector.assess(record: record, samples: samples, policy: tight) == .exceeded(deviationDB: 5))
    }

    // MARK: gateAfterDrift

    @Test func autoDisarmOffKeepsTheGateArmedEvenWhenExceeded() {
        // MVP default: detect and report, never disarm.
        #expect(policy.autoDisarmOnDrift == false)
        let armed = CalibrationGate.armed(CalFixture.profile)
        let after = detector.gateAfterDrift(armed, assessment: .exceeded(deviationDB: 20), policy: policy)
        #expect(after == armed)
    }

    @Test func autoDisarmOnDisarmsWhenExceeded() {
        var p = CalibrationPolicy()
        p.autoDisarmOnDrift = true
        let after = detector.gateAfterDrift(
            .armed(CalFixture.profile), assessment: .exceeded(deviationDB: 20), policy: p)
        #expect(after == .notArmed(.driftExceeded))
    }

    @Test func autoDisarmOnDoesNotDisarmOnSuspectedOrNone() {
        var p = CalibrationPolicy()
        p.autoDisarmOnDrift = true
        let armed = CalibrationGate.armed(CalFixture.profile)
        #expect(detector.gateAfterDrift(armed, assessment: .suspected(deviationDB: 10), policy: p) == armed)
        #expect(detector.gateAfterDrift(armed, assessment: .none, policy: p) == armed)
    }

    @Test func anAlreadyNotArmedGateIsPassedThroughUnchanged() {
        var p = CalibrationPolicy()
        p.autoDisarmOnDrift = true
        let notArmed = CalibrationGate.notArmed(.macMismatch)
        #expect(detector.gateAfterDrift(notArmed, assessment: .none, policy: p) == notArmed)
        // Drift only ever disarms; it never re-arms, and never overwrites a reason
        // the operator still needs to see.
        #expect(detector.gateAfterDrift(notArmed, assessment: .exceeded(deviationDB: 20), policy: p)
                == notArmed)
    }

    @Test func driftNeverArmsAGate() {
        var p = CalibrationPolicy()
        p.autoDisarmOnDrift = true
        for assessment: DriftAssessment in [.none, .suspected(deviationDB: 10), .exceeded(deviationDB: 20)] {
            for gate in [CalibrationGate.notArmed(.noProfile), .armed(CalFixture.profile)] {
                let after = detector.gateAfterDrift(gate, assessment: assessment, policy: p)
                if case .armed = after { #expect(gate.isArmed) }
            }
        }
    }
}
