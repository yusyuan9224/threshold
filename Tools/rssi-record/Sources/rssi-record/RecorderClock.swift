import ThresholdBluetooth
import ThresholdDomain

/// The recorder's `BLEClock`: stamps boundary events with monotonic time
/// (architecture.md §4.2 — time is produced at the boundary, never in the Domain).
///
/// `ContinuousClock` rather than `SuspendingClock` / `mach_absolute_time`: field runs
/// deliberately span display sleep and, for the `wake-after-sleep` scenario, system
/// sleep. A clock that stopped advancing across a sleep would erase exactly the
/// silent gap the engine has to survive, and the fixture would understate it.
///
/// `origin` is captured once so `MonotonicInstant.nanoseconds` starts near zero and
/// stays well inside `Int64` for any plausible run length.
struct ContinuousBLEClock: BLEClock {
    private let origin: ContinuousClock.Instant

    init(origin: ContinuousClock.Instant = ContinuousClock.now) {
        self.origin = origin
    }

    func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: (ContinuousClock.now - origin).wholeNanoseconds)
    }
}
