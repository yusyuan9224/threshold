/// Three explainable factors multiplied into one value (docs/specs/proximity-domain.md §3.1).
public struct PresenceScore: Sendable, Equatable {
    /// distance × recency × sufficiency, in [0, 1].
    public let value: Double
    /// logistic((smoothedRSSI − midpoint) / slope): how "near" the signal is relative to the calibrated baselines.
    public let distance: Double
    /// 1 while age ≤ 2 s, linearly decaying to 0 at age = silentThreshold. Smooths the last seconds before silence only.
    public let recency: Double
    /// min(1, sampleCount / minSamples): too few samples are not trustworthy.
    public let sufficiency: Double

    public init(distance: Double, recency: Double, sufficiency: Double) {
        self.distance = distance
        self.recency = recency
        self.sufficiency = sufficiency
        self.value = distance * recency * sufficiency
    }
}

/// Axis 3: has this device been heard from recently? Independent of presence and sensor health.
public enum DeviceObservationState: Sendable, Equatable {
    case receiving
    case silent(since: MonotonicInstant)
}

/// Per-device signal state exposed by the engine. The data shape is multi-device from day one;
/// only the fusion strategy is single-device in MVP.
public struct DeviceTrack: Sendable, Equatable {
    public let device: DeviceID
    public let observation: DeviceObservationState
    public let estimate: SignalEstimate?
    /// Present only while `observation == .receiving` and an estimate exists.
    public let score: PresenceScore?
    public let isCalibrated: Bool

    public init(device: DeviceID, observation: DeviceObservationState, estimate: SignalEstimate?, score: PresenceScore?, isCalibrated: Bool) {
        self.device = device
        self.observation = observation
        self.estimate = estimate
        self.score = score
        self.isCalibrated = isCalibrated
    }
}

/// Seam for future multi-device strategies. Only `receiving` devices contribute; `nil` means no evidence at all.
public protocol PresenceFusion: Sendable {
    func fuse(_ tracks: [DeviceTrack]) -> Double?
}
