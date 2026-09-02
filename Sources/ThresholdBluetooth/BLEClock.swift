import ThresholdDomain

/// The single time operation the Bluetooth adapter needs: stamp an event at the
/// boundary with monotonic time (architecture.md §4.2 — time is produced at the
/// boundary; the Domain never reads a clock).
///
/// The full `MonotonicClock` (which also has `sleep(until:)`) belongs to
/// `ThresholdSystem`, and `ThresholdBluetooth` must not depend on `ThresholdSystem`
/// (architecture.md §2.2/§2.3). So this target declares only the operation it uses;
/// the composition root adapts the system clock to `BLEClock`.
public protocol BLEClock: Sendable {
    func now() -> MonotonicInstant
}
