import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdRuntime

/// L3: scheduling, stream lifecycle and shutdown (architecture.md §5.4).
@Suite struct CoordinatorLifecycleTests {

    /// The deadline task is the only thing that makes time pass for the engine, so a rule that
    /// depends on silence must fire from an advance of the clock alone — no test-supplied tick.
    @Test func deadlineTickFiresAtTheEnginesNextDeadline() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)

        let scheduled = await harness.snapshot.nextDeadline
        #expect(scheduled == at(16), "last sample at t=6 plus silentThreshold")

        #expect(await waitForSleepers(harness.clock))
        harness.clock.advance(to: at(16))

        #expect(await waitUntil {
            harness.collector.transitions.contains { $0.cause == .deviceSilent }
        }, "the scheduled tick, not the test, produced the device transition")
        #expect(await harness.snapshot.presence == .present, "silence is not absence")
    }

    /// System sleep: scanning pauses, the timer is dropped, and nothing is scheduled while the
    /// machine is down.
    @Test func systemWillSleepPausesScanningAndCancelsTheDeadline() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)
        #expect(await waitForSleepers(harness.clock))

        await harness.coordinator.handle(.lifecycle(.systemWillSleep))

        #expect(harness.scanner.pauseCount == 1)
        #expect(await waitUntil { harness.clock.pendingSleepers == 0 }, "the deadline task was cancelled")
        #expect(await waitUntil { harness.collector.lifecycleEvents.contains(.systemWillSleep) })
    }

    /// System wake: scanning resumes, presence is reset, and the freshest possible evidence still
    /// cannot produce an action inside the confirm window.
    @Test func systemDidWakeResetsPresenceAndResumesScanning() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)
        await harness.coordinator.handle(.lifecycle(.systemWillSleep))

        await harness.coordinator.handle(.lifecycle(.systemDidWake))

        #expect(harness.scanner.resumeCount == 1)
        #expect(await waitUntil { harness.collector.transitions.contains { $0.cause == .reset(.systemWake) } })
        #expect(await harness.snapshot.presence == .unknown(.reset(.systemWake)))

        await harness.flood(farRSSI, from: 6, through: 8.9, step: 0.1)
        await settle()
        #expect(harness.lock.lockCount == 0)
        #expect(harness.wake.wakeCount == 0)
    }

    /// A display going dark says nothing about where the user is, so it moves `power` and nothing
    /// else.
    @Test func screenSleepAndWakeOnlyMovePowerState() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)
        let episodeBefore = await harness.snapshot.episode

        await harness.coordinator.handle(.lifecycle(.screensDidSleep))
        await harness.coordinator.handle(.lifecycle(.screensDidWake))
        await settle()

        let after = await harness.snapshot
        #expect(after.episode == episodeBefore, "no reset, so no new episode")
        #expect(after.presence == .present)
        #expect(!harness.collector.transitions.contains { $0.cause == .reset(.systemWake) })
    }

    /// An observation stream that ends is treated as the adapter dying: the sensor axis fails
    /// closed and scanning is restarted a bounded number of times.
    @Test func endedObservationStreamFailsClosedAndRestartsAtMostThreeTimes() async {
        let harness = RuntimeHarness()
        await harness.start()
        let startCallsBefore = harness.scanner.startCalls.count

        harness.scanner.finish()
        #expect(await waitUntil { await harness.snapshot.sensor == .unavailable(.scannerFailed) })

        // Each restart waits out `scannerRestartDelay` on the fake clock.
        for _ in 0..<5 {
            _ = await waitForSleepers(harness.clock)
            harness.clock.advance(by: .seconds(2))
            await settle(4)
        }

        #expect(harness.collector.restartAttempts == [1, 2, 3])
        #expect(harness.scanner.startCalls.count == startCallsBefore + 3)
    }

    /// T-18 (L3). The observation channel is lossy and the sensor channel is not, so a flood on the
    /// first must never delay or drop an event on the second.
    @Test func t18_observationFloodDoesNotStarveTheSensorChannel() async {
        let harness = RuntimeHarness()
        await harness.start()

        for index in 0..<500 {
            harness.scanner.emit(observation: BLEObservation(
                device: deviceA, at: at(Double(index) * 0.01), rssi: nearRSSI
            ))
        }
        harness.clock.advance(to: at(5))
        harness.scanner.emit(sensor: .unavailable(.poweredOff), at: at(5))

        #expect(await waitUntil { await harness.snapshot.sensor == .unavailable(.poweredOff) })
    }

    /// Shutdown: a committed lock is allowed to finish, and the outcome that arrives afterwards is
    /// ignored rather than applied to a Coordinator that is no longer running.
    @Test func stopLetsAnInFlightLockFinishAndIgnoresItsLateOutcome() async {
        let harness = RuntimeHarness(gatedLock: true)
        await harness.start()
        await harness.driveToAway()
        #expect(await waitUntil { harness.lock.pendingCount == 1 })

        let ledgerBeforeStop = await harness.ledger
        await harness.coordinator.stop()

        harness.lock.release()
        await settle()

        #expect(harness.lock.lockCount == 1, "the in-flight lock was not cancelled")
        let ledgerAfterStop = await harness.ledger
        #expect(ledgerAfterStop == ledgerBeforeStop, "the late outcome did not touch the ledger")
        #expect(!harness.collector.acknowledgements.contains { $0.0 == ActionID(1) })
    }

    /// After `stop()` no further input is accepted, so a stray event cannot restart the machinery.
    @Test func stopIgnoresSubsequentInput() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.coordinator.stop()

        await harness.driveToAway()
        await settle()

        #expect(harness.lock.lockCount == 0)
        #expect(await harness.snapshot.presence == .unknown(.initial))
    }

    /// A changed trusted-device set restarts scanning and the whole proximity subsystem: evidence
    /// gathered about the old set is not evidence about the new one (security.md §2.5).
    @Test func devicesChangedRestartsScanningAndResetsPresence() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)
        #expect(await harness.snapshot.presence == .present)

        let deviceB = DeviceID("bbbbbbbb-2222-3333-4444-555555555555")
        await harness.coordinator.handle(.devicesChanged([deviceA, deviceB]))

        #expect(harness.scanner.monitoredDevices == [deviceA, deviceB])
        let after = await harness.snapshot
        #expect(after.presence == .unknown(.reset(.devicesChanged)))
        #expect(after.sensor == .healthy, "the last known sensor status is replayed into the new engine")
        #expect(after.devices.keys.sorted { $0.raw < $1.raw }.count == 2)
        #expect(await harness.ledger.isEmpty)
    }
}
