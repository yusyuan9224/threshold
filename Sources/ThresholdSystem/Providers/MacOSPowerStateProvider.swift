import CoreGraphics
import Foundation
import os
import ThresholdDomain

/// The `NSWorkspace` power signals, mapped to `PowerState`.
public enum PowerSignal: Sendable, Equatable {
    case willSleep
    case didWake
    case screensDidSleep
    case screensDidWake
}

/// Pure mapping for `PowerStateProviding`, so the table is covered without a real device.
public enum PowerStateMapping {
    public static func state(for signal: PowerSignal) -> PowerState {
        switch signal {
        case .willSleep: return .systemAsleep
        case .didWake: return .awake
        case .screensDidSleep: return .displayAsleep
        case .screensDidWake: return .awake
        }
    }

    public static func state(displayIsAsleep: Bool) -> PowerState {
        displayIsAsleep ? .displayAsleep : .awake
    }
}

/// Production `PowerStateProviding`.
///
/// Display sleep is queryable (`CGDisplayIsAsleep`); system sleep is not, because the process is
/// frozen for its whole duration. So `current` reads the display live and falls back to the last
/// notification only for `.systemAsleep`, which by construction can only be observed on the way in.
public final class MacOSPowerStateProvider: PowerStateProviding, Sendable {
    private let clock: any MonotonicClock
    private let reported: OSAllocatedUnfairLock<PowerState>
    private let stream: AsyncStream<Timestamped<PowerState>>
    private let continuation: AsyncStream<Timestamped<PowerState>>.Continuation
    private let observers = NotificationObservers()

    public init(clock: any MonotonicClock) {
        self.clock = clock
        reported = OSAllocatedUnfairLock(initialState: PowerStateMapping.state(displayIsAsleep: Self.displayIsAsleep()))
        let (stream, continuation) = AsyncStream<Timestamped<PowerState>>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation

        let workspace = NSWorkspaceNotifications.center
        observers.add(workspace, name: NSWorkspaceNotifications.willSleep) { [weak self] in self?.update(.willSleep) }
        observers.add(workspace, name: NSWorkspaceNotifications.didWake) { [weak self] in self?.update(.didWake) }
        observers.add(workspace, name: NSWorkspaceNotifications.screensDidSleep) { [weak self] in self?.update(.screensDidSleep) }
        observers.add(workspace, name: NSWorkspaceNotifications.screensDidWake) { [weak self] in self?.update(.screensDidWake) }
    }

    deinit {
        observers.removeAll()
        continuation.finish()
    }

    public var current: PowerState {
        let cached = reported.withLock { $0 }
        guard cached != .systemAsleep else { return .systemAsleep }
        return PowerStateMapping.state(displayIsAsleep: Self.displayIsAsleep())
    }

    public var changes: AsyncStream<Timestamped<PowerState>> { stream }

    private func update(_ signal: PowerSignal) {
        let next = PowerStateMapping.state(for: signal)
        let changed = reported.withLock { reported -> Bool in
            guard reported != next else { return false }
            reported = next
            return true
        }
        guard changed else { return }
        continuation.yield(Timestamped(next, at: clock.now()))
    }

    private static func displayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
}
