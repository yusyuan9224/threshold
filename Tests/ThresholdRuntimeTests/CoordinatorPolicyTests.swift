import Testing
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdRuntime

/// L3: the three axes, Policy, the ledger and the deadline scheduler working together
/// (docs/specs/testing.md §1). Every boundary is a Fake; nothing in the path under test is stubbed.
@Suite struct CoordinatorPolicyTests {

    /// T-03 (L3). A sensing subsystem that is not healthy invalidates every belief downstream of it,
    /// so the last known `away` must not be acted on however inviting the rest of the state looks.
    ///
    /// The screen starts locked so evidence can build up without a lock firing for the ordinary
    /// reason; unlocking it afterwards is exactly the shape that *would* lock with a healthy sensor.
    @Test(arguments: [SensorStatus.unavailable(.poweredOff), .degraded(.scanInterrupted)])
    func t03_t12_unhealthySensorNeverLocks(status: SensorStatus) async {
        let harness = RuntimeHarness(screen: .locked)
        await harness.start()
        await harness.driveToAway()

        let afterDeparture = await harness.snapshot
        #expect(afterDeparture.presence == .away)
        #expect(harness.lock.lockCount == 0)

        await harness.coordinator.handle(.sensor(status, at: at(21)))
        await harness.setScreen(.unlocked, at: 22)
        await harness.tick(30)
        await settle()

        let afterFailure = await harness.snapshot
        #expect(afterFailure.presence == .away, "presence keeps its last known value; a sensor fact is not a user fact")
        #expect(harness.lock.lockCount == 0)
        #expect(harness.collector.dispatched.isEmpty)
        #expect(harness.collector.rationaleContains(.preconditionIndeterminate(.sensor)))
    }

    /// T-07 (L3). The lock is held mid-flight while presence recovers, so the outcome lands in an
    /// episode that no longer exists.
    @Test func t07_outcomeFromSupersededEpisodeIsStale() async {
        // A long retry window keeps the scenario about staleness: the eleven seconds presence needs
        // to recover would otherwise cross `retryAfter` and legitimately re-propose the lock.
        var settings = PolicySettings()
        settings.retryAfter = .seconds(600)
        let harness = RuntimeHarness(settings: settings, gatedLock: true)
        await harness.start()

        await harness.driveToAway()
        #expect(await waitUntil { harness.lock.pendingCount == 1 })
        let lockedEpisode = await harness.snapshot.episode
        #expect(harness.collector.dispatched.count == 1)

        await harness.drive(nearRSSI, from: 21, through: 31)
        let recovered = await harness.snapshot
        #expect(recovered.presence == .present)
        #expect(recovered.episode != lockedEpisode)
        let ledgerBeforeOutcome = await harness.ledger

        harness.lock.release()
        #expect(await waitUntil { harness.collector.acknowledgements.contains { $0.2 == .stale } })
        await settle()

        let ledgerAfterOutcome = await harness.ledger
        #expect(ledgerAfterOutcome == ledgerBeforeOutcome, "a stale outcome must not move the ledger")
        #expect(ledgerAfterOutcome.count == 1)
        #expect(ledgerAfterOutcome[0].stage == .stale)
        #expect(harness.lock.lockCount == 1, "a stale outcome must never re-dispatch")
        #expect(harness.collector.dispatched.count == 1)
    }

    /// T-08 (L3). A reset throws away every sample, so the fastest possible flood still cannot beat
    /// `minSamples + confirmDuration`. Far observations are used because they are the only kind that
    /// could ever produce a lock.
    @Test func t08_noLockWithinConfirmDurationOfSystemWake() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.drive(nearRSSI, from: 0, through: 6)

        await harness.coordinator.handle(.lifecycle(.systemDidWake))
        let afterWake = await harness.snapshot
        #expect(afterWake.presence == .unknown(.reset(.systemWake)))

        // 30 samples in 2.9 s: far past `minSamples`, one tenth of a second short of the hold.
        await harness.flood(farRSSI, from: 6, through: 8.9, step: 0.1)
        await settle()

        let justBefore = await harness.snapshot
        #expect(justBefore.presence != .away)
        #expect(harness.lock.lockCount == 0)
        #expect(harness.collector.dispatched.isEmpty)

        // One more sample carries the run past confirmDuration, and only now may anything act.
        await harness.observe(farRSSI, at: 9.0)
        #expect(await harness.snapshot.presence == .away)
        #expect(await waitUntil { harness.lock.lockCount == 1 })
    }

    /// T-09 (L3). Five snapshots in a row with the screen still unlocked — the shape produced by a
    /// lock that has not taken effect yet — must not turn into five locks.
    @Test func t09_repeatedSnapshotsDispatchOneLock() async {
        let harness = RuntimeHarness()
        await harness.start()
        await harness.driveToAway()
        #expect(await waitUntil { harness.lock.lockCount == 1 })

        for _ in 0..<5 { await harness.setScreen(.unlocked, at: 20) }
        await settle()

        #expect(harness.lock.lockCount == 1)
        #expect(harness.collector.dispatched.count == 1)
        #expect(harness.collector.rationaleContains(.alreadyIssued(ActionID(1))))
        let ledger = await harness.ledger
        #expect(ledger.count == 1)
        #expect(ledger[0].attempts == 1)
    }

    /// The wake counterpart: one wake on the arrival edge, none once the window has passed.
    @Test func wakeFiresOnceOnTheArrivalEdge() async {
        let harness = RuntimeHarness(screen: .locked, power: .displayAsleep)
        await harness.start()

        await harness.drive(nearRSSI, from: 0, through: 6)
        #expect(await waitUntil { harness.wake.wakeCount == 1 })

        // A steady presence emits no transition, so an explicit tick is what forces the
        // re-evaluation this assertion is about.
        await harness.drive(nearRSSI, from: 7, through: 10)
        await harness.tick(10)
        await settle()
        #expect(harness.wake.wakeCount == 1, "still the same arrival, still one wake")
        #expect(harness.collector.rationaleContains(.alreadyIssued(ActionID(1))))

        // wakeWindow is 30 s from presenceSince (t = 6); this run ends well past it.
        await harness.drive(nearRSSI, from: 11, through: 45)
        await harness.tick(45)
        await settle()
        #expect(harness.wake.wakeCount == 1)
        #expect(harness.lock.lockCount == 0)
        #expect(harness.collector.rationaleContains(.outsideWakeWindow))
    }

    /// A lock that fails is retried from the ledger, not from the controller, and gives up at
    /// `maxAttempts` rather than looping.
    @Test func failedLockRetriesThenGivesUp() async {
        var settings = PolicySettings()
        settings.retryAfter = .seconds(5)
        settings.maxAttempts = 3
        let harness = RuntimeHarness(settings: settings)
        harness.lock.fail()
        await harness.start()

        await harness.driveToAway()
        #expect(await waitUntil { harness.lock.lockCount >= 1 })

        // Each failed outcome is retry-eligible immediately, so ticks are only needed to keep the
        // engine's own clock moving alongside policy's.
        for seconds in stride(from: 21.0, through: 60.0, by: 5.0) {
            await harness.tick(seconds)
            await settle(3)
        }

        let ledger = await harness.ledger
        #expect(ledger.count == 1)
        #expect(ledger[0].attempts <= settings.maxAttempts)
        #expect(harness.lock.lockCount <= settings.maxAttempts)
        #expect(harness.collector.rationaleContains(.gaveUp(ActionID(1))))
    }

    /// `autoLock == false` is honoured all the way through the integration, not just in the pure
    /// policy unit (T-05 at L3).
    @Test func autoLockDisabledNeverLocks() async {
        var settings = PolicySettings()
        settings.autoLock = false
        let harness = RuntimeHarness(settings: settings)
        await harness.start()

        await harness.driveToAway()
        await harness.tick(40)
        await settle()

        #expect(await harness.snapshot.presence == .away)
        #expect(harness.lock.lockCount == 0)
        #expect(harness.collector.rationaleContains(.disabledBySettings))
    }

    /// An unarmed calibration gate blocks the action, and arming it later is a policy input rather
    /// than a presence one (T-17 at L3).
    @Test func unarmedCalibrationBlocksLockUntilArmed() async {
        let harness = RuntimeHarness(gate: .notArmed(.noProfile))
        await harness.start()

        // The uncalibrated fallback profile is a slightly gentler curve, so `departing` starts a
        // second later and `away` needs the run extended past `departureDelay`.
        await harness.drive(nearRSSI, from: 0, through: 6)
        await harness.drive(farRSSI, from: 7, through: 25)
        await settle()
        #expect(harness.lock.lockCount == 0)
        #expect(harness.collector.rationaleContains(.preconditionUnsatisfied(.calibration)))

        await harness.coordinator.handle(.calibrationChanged(.armed(testProfile)))
        #expect(await waitUntil { harness.lock.lockCount == 1 })
        #expect(await harness.snapshot.presence == .away, "a better yardstick is not evidence that the user moved")
    }
}
