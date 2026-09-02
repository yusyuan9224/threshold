import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdRuntime

/// MEDIUM-2 (architecture.md §5.1): `events` must not drop an audit event under backpressure, and
/// must not let a flood of no-op observations turn `snapshotUpdated` into one event per input.
@Suite struct CoordinatorEventStreamTests {

    /// A raw backlog test, deliberately not going through `RuntimeHarness`: nothing here reads
    /// `events` until every event has already been produced, so whatever the buffering policy keeps
    /// is exactly what a consumer this far behind would see. `.bufferingNewest(1024)` would keep
    /// only the newest 1024 of the 2000 emitted below and silently discard the rest; `.unbounded`
    /// keeps all of them.
    @Test func eventsStreamNeverDropsUnderBacklog() async {
        let deviceSet: Set<DeviceID> = [deviceA]
        let makeEngine: @Sendable (Set<DeviceID>, CalibrationGate) -> ProximityEngine = { devices, gate in
            ProximityEngine(configuration: EngineConfiguration(), fusion: AnyDeviceFusion(), devices: devices, gate: gate)
        }
        let coordinator = Coordinator(
            scanner: FakeScanner(),
            screen: FakeScreenStateProvider(initial: .unlocked),
            session: FakeSessionStateProvider(initial: .active),
            power: FakePowerStateProvider(initial: .awake),
            input: FakeInputActivityProvider(idle: .seconds(300)),
            lock: GatedLockController(),
            wake: SpyWakeController(),
            clock: FakeClock(start: at(0)),
            engine: makeEngine(deviceSet, .armed(testProfile)),
            policy: PolicyEngine(),
            settings: PolicySettings(),
            gate: .armed(testProfile),
            devices: deviceSet,
            makeEngine: makeEngine
        )

        let total = 2000
        for index in 0..<total {
            // `emit` is `nonisolated`: this is exactly the audit-event shape (`lifecycle`), produced
            // faster than anything is consuming it, which is the scenario a bounded buffer loses.
            coordinator.emit(.lifecycle(index.isMultiple(of: 2) ? .screensDidSleep : .screensDidWake))
        }
        await coordinator.stop() // finishes the stream so iteration below terminates.

        var received: [CoordinatorEvent] = []
        for await event in coordinator.events { received.append(event) }

        #expect(received.count == total, "an unbounded stream must not drop events under backlog")
    }

    /// T-matches MEDIUM-2's description directly: 10,000 observations that never transition must
    /// yield far fewer `snapshotUpdated` events than inputs, and the lock this run eventually
    /// dispatches — plus its acknowledgement — must still be observed once the flood is over.
    @Test func floodOfNoOpObservationsCoalescesSnapshotsWithoutLosingAuditEvents() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)
        #expect(await harness.snapshot.presence == .present)

        func snapshotUpdateCount() -> Int {
            harness.collector.events.reduce(into: 0) { count, event in
                if case .snapshotUpdated = event { count += 1 }
            }
        }
        let before = snapshotUpdateCount()

        let total = 10_000
        for index in 0..<total {
            await harness.observe(nearRSSI, at: 6 + Double(index + 1) * 0.001)
        }

        let afterFlood = snapshotUpdateCount() - before
        #expect(afterFlood < total / 10, "a run with no transitions must not publish one snapshotUpdated per input")
        #expect(
            !harness.collector.transitions.contains { $0.at > at(6) && $0.at <= at(6 + Double(total) * 0.001) },
            "the flood was constructed to hold steady presence; a transition here would invalidate the count above"
        )

        // The audit trail must still be intact once real evidence follows the flood.
        await harness.drive(farRSSI, from: 17, through: 30)
        #expect(await waitUntil { harness.lock.lockCount == 1 })
        #expect(await waitUntil { harness.collector.dispatched.count == 1 })
        #expect(await waitUntil { harness.collector.acknowledgements.contains { $0.2 == .applied } })
    }
}
