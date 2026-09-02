/// MVP fusion strategy: the strongest score among devices we are currently hearing
/// (docs/specs/proximity-domain.md §3.4).
///
/// Only `receiving` devices contribute. This is the mechanism that separates silence from
/// absence: a device that stopped talking contributes nothing at all, rather than contributing
/// a zero that would look like measured distance. `nil` therefore means "no evidence",
/// which the state machine treats very differently from "evidence of being far away".
public struct AnyDeviceFusion: PresenceFusion {
    public init() {}

    public func fuse(_ tracks: [DeviceTrack]) -> Double? {
        var best: Double?
        for track in tracks where track.observation == .receiving {
            guard let value = track.score?.value else { continue }
            if let current = best {
                best = value > current ? value : current
            } else {
                best = value
            }
        }
        return best
    }
}
