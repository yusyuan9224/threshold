import Testing
@testable import ThresholdDomain

private func at(_ seconds: Double) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: Int64(seconds * 1_000_000_000))
}

@Suite("SignalWindow (§2)")
struct SignalWindowTests {
    @Test func keepsOnlyTheMostRecentSamplesUpToSize() {
        var window = SignalWindow(size: 3, horizon: .seconds(60))
        for (index, rssi) in [-60, -61, -62, -63, -64].enumerated() {
            window.append(rssi: rssi, at: at(Double(index)))
        }
        #expect(window.count == 3)
        #expect(window.values == [-62, -63, -64])
    }

    @Test func evictsSamplesOlderThanTheHorizonRelativeToTheNewest() {
        var window = SignalWindow(size: 7, horizon: .seconds(15))
        window.append(rssi: -50, at: at(0))
        window.append(rssi: -51, at: at(10))
        window.append(rssi: -52, at: at(20))
        // The sample at t=0 is 20 s behind the newest and drops out; t=10 is exactly at the horizon and stays.
        #expect(window.values == [-51, -52])
        #expect(window.newest?.at == at(20))
    }

    @Test func medianAbsoluteDeviationIgnoresASingleSpike() {
        var window = SignalWindow(size: 7, horizon: .seconds(15))
        for (index, rssi) in [-62, -61, -20, -63, -64].enumerated() {
            window.append(rssi: rssi, at: at(Double(index)))
        }
        // median = -62; deviations 0,1,42,1,2 → MAD = 1
        #expect(window.medianAbsoluteDeviation == 1.0)
    }

    @Test func emptyWindowHasNoNewestAndZeroSpread() {
        let window = SignalWindow(size: 7, horizon: .seconds(15))
        #expect(window.isEmpty)
        #expect(window.newest == nil)
        #expect(window.medianAbsoluteDeviation == 0)
    }
}

@Suite("MedianFilter / EMAFilter (§2)")
struct FilterTests {
    @Test func medianOfOddCountIsTheMiddleValue() {
        #expect(MedianFilter.median(of: [-64, -63, -62, -61, -20]) == -62)
    }

    @Test func medianOfEvenCountAveragesTheTwoMiddleValues() {
        #expect(MedianFilter.median(of: [-63, -62, -61, -20]) == -61.5)
    }

    @Test func medianOfEmptyIsNil() {
        #expect(MedianFilter.median(of: []) == nil)
    }

    @Test func medianFilterUsesTheNewestSpanSamplesOnly() {
        var window = SignalWindow(size: 7, horizon: .seconds(60))
        for (index, rssi) in [-90, -90, -62, -61, -20, -63, -64].enumerated() {
            window.append(rssi: rssi, at: at(Double(index)))
        }
        let filter = MedianFilter(span: 5)
        // Newest five are -62 -61 -20 -63 -64; the two -90s are outside the span.
        #expect(filter.filter(window) == -62)
    }

    @Test func medianFilterFallsBackToAvailableCountBelowSpan() {
        var window = SignalWindow(size: 7, horizon: .seconds(60))
        window.append(rssi: -62, at: at(0))
        window.append(rssi: -61, at: at(1))
        #expect(MedianFilter(span: 5).filter(window) == -61.5)
    }

    @Test func emaSeedsOnTheFirstSample() {
        var ema = EMAFilter(alpha: 0.3)
        #expect(ema.value == nil)
        #expect(ema.update(-62) == -62)
    }

    @Test func emaWeightsTheNewSampleByAlpha() {
        var ema = EMAFilter(alpha: 0.3)
        _ = ema.update(-62)
        #expect(abs(ema.update(-61.5) - (-61.85)) < 1e-12)
    }
}

@Suite("SignalPipeline (§2)")
struct SignalPipelineTests {
    private let configuration = EngineConfiguration()

    @Test func firstSampleProducesAnEstimateSeededAtThatSample() {
        var pipeline = SignalPipeline(configuration: configuration)
        let estimate = pipeline.ingest(rssi: -62, at: at(0))
        #expect(estimate.smoothedRSSI == -62)
        #expect(estimate.sampleCount == 1)
        #expect(estimate.lastSeen == at(0))
        #expect(estimate.spread == 0)
    }

    /// T-01 (L1): the `-20` spike must not drag the smoothed value toward "near".
    @Test func t01_singleSpikeDoesNotMoveTheSmoothedValue() {
        var pipeline = SignalPipeline(configuration: configuration)
        var estimate: SignalEstimate?
        for (index, rssi) in [-62, -61, -20, -63, -64].enumerated() {
            estimate = pipeline.ingest(rssi: rssi, at: at(Double(index)))
        }
        let smoothed = try! #require(estimate).smoothedRSSI
        // Median-before-EMA keeps the spike out: exact expected chain is
        // -62 → -61.85 → -61.595 → -61.5665 → -61.69655
        #expect(abs(smoothed - (-61.69655)) < 1e-9)
        #expect(abs(smoothed - (-62)) < 3, "spike moved the smoothed value by more than 3 dB")
    }

    @Test func t01_withoutTheMedianStageTheSpikeWouldDominate() {
        // Control: the same sequence fed straight into the EMA is pulled 5+ dB nearer,
        // which is what the median stage exists to prevent.
        var ema = EMAFilter(alpha: 0.3)
        var raw = 0.0
        for rssi in [-62, -61, -20, -63, -64] { raw = ema.update(Double(rssi)) }
        var pipeline = SignalPipeline(configuration: configuration)
        var filtered = 0.0
        for (index, rssi) in [-62, -61, -20, -63, -64].enumerated() {
            filtered = pipeline.ingest(rssi: rssi, at: at(Double(index))).smoothedRSSI
        }
        #expect(abs(raw - (-56.5331)) < 1e-4)
        #expect(raw - filtered > 5, "control: raw EMA is dragged toward near by the spike")
    }

    @Test func spreadIsTheWindowMedianAbsoluteDeviation() {
        var pipeline = SignalPipeline(configuration: configuration)
        var estimate: SignalEstimate?
        for (index, rssi) in [-62, -61, -20, -63, -64].enumerated() {
            estimate = pipeline.ingest(rssi: rssi, at: at(Double(index)))
        }
        #expect(estimate?.spread == 1.0)
        #expect(estimate?.sampleCount == 5)
    }

    @Test func sampleCountTracksTheWindowAfterHorizonEviction() {
        var pipeline = SignalPipeline(configuration: configuration)
        _ = pipeline.ingest(rssi: -60, at: at(0))
        _ = pipeline.ingest(rssi: -60, at: at(1))
        let estimate = pipeline.ingest(rssi: -60, at: at(40))
        #expect(estimate.sampleCount == 1, "samples older than the 15 s horizon are evicted")
        #expect(estimate.lastSeen == at(40))
    }

    @Test func resetClearsWindowAndSmoothing() {
        var pipeline = SignalPipeline(configuration: configuration)
        _ = pipeline.ingest(rssi: -30, at: at(0))
        pipeline.reset()
        #expect(pipeline.estimate == nil)
        #expect(pipeline.ingest(rssi: -80, at: at(1)).smoothedRSSI == -80)
    }
}
