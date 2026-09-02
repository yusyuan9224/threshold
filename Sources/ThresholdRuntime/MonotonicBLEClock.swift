import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// Adapts the system `MonotonicClock` to the one operation `ThresholdBluetooth` declares for
/// itself (`BLEClock.now()`).
///
/// The adapter lives here because `ThresholdRuntime` is the lowest layer that may see both targets:
/// Bluetooth must not depend on System (architecture.md §2.2/§2.3), so it declares the narrow
/// protocol and someone above both of them supplies the implementation.
public struct MonotonicBLEClock: BLEClock, Sendable {
    private let clock: any MonotonicClock

    public init(_ clock: any MonotonicClock) {
        self.clock = clock
    }

    public func now() -> MonotonicInstant { clock.now() }
}
