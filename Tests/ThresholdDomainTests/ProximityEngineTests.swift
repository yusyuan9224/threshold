import Testing
@testable import ThresholdDomain

@Suite("ProximityEngine — presence transition table (§4.3)")
struct ProximityEngineTransitionTests {
    @Test("#1 unknown → present after minSamples and confirmDuration")
    func unknownToPresent() {
        var harness = Harness()
        harness.drive(nearRSSI, from: 0, through: 6)
        #expect(harness.presenceSteps == [Step("present", .confirmedNear)])
        #expect(harness.presence == .present)
        #expect(harness.snapshot.evidence == .measuredNear)
        #expect(harness.presenceTransitions.first?.at == instant(6))
        #expect(harness.presenceTransitions.first?.from == "unknown(initial)")
    }

    @Test("#1 cannot fire before the confirm duration has elapsed")
    func confirmDurationIsRequired() {
        var harness = Harness()
        harness.drive(nearRSSI, from: 0, through: 5)
        #expect(harness.presence == .unknown(.initial))
        harness.observe(nearRSSI, at: 6)
        #expect(harness.presence == .present)
    }

    @Test("#2 unknown → away on sustained measured-far evidence")
    func unknownToAway() {
        var harness = Harness()
        harness.drive(farRSSI, from: 0, through: 4)
        #expect(harness.presenceSteps == [Step("away", .measuredFar)])
        #expect(harness.snapshot.evidence == .measuredFar)
        #expect(harness.presenceTransitions.first?.at == instant(4))
    }

    @Test("#3 present → departing on measured weakening")
    func presentToDeparting() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 10)
        #expect(harness.presenceSteps.last == Step("departing", .signalWeakened))
        #expect(harness.presenceTransitions.last?.at == instant(10))
        // Evidence is unchanged by #3: we measured weakening, not distance.
        #expect(harness.snapshot.evidence == .measuredNear)
    }

    @Test("#4 departing → present on recovery, without waiting for a confirm duration")
    func departingToPresent() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 10)
        #expect(harness.presence == .departing)
        harness.drive(nearRSSI, from: 11, through: 20)
        #expect(harness.presenceSteps.last == Step("present", .signalRecovered))
        #expect(harness.snapshot.evidence == .measuredNear)
    }

    @Test("#5 departing → away after departureDelay while still receiving")
    func departingToAwayWhileReceiving() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 20)
        #expect(harness.presenceSteps == [
            Step("present", .confirmedNear),
            Step("departing", .signalWeakened),
            Step("away", .measuredFar),
        ])
        #expect(harness.presenceTransitions.last?.at == instant(20))
        #expect(harness.snapshot.evidence == .measuredFar)
    }

    @Test("#5 does not fire before departureDelay elapses")
    func departureDelayIsRequired() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 19)
        #expect(harness.presence == .departing)
    }

    @Test("#9 away → present after confirmDuration")
    func awayToPresent() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 20)
        #expect(harness.presence == .away)
        harness.drive(nearRSSI, from: 21, through: 31)
        #expect(harness.presenceSteps.last == Step("present", .confirmedNear))
        #expect(harness.snapshot.evidence == .measuredNear)
    }

    @Test("#10 away → unknown once every device has been silent for evidenceTimeout")
    func awayToUnknown() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 20)
        #expect(harness.presence == .away)
        harness.tick(40)
        #expect(harness.presence == .away, "evidenceTimeout runs from the last observation at t=20")
        harness.tick(51)
        #expect(harness.presenceSteps.last == Step("unknown(evidenceExpired)", .evidenceExpired))
        #expect(harness.snapshot.evidence == .none)
    }

    @Test("#11 reset returns presence to unknown and increments the episode")
    func resetTransition() {
        var harness = harnessAtPresent()
        let before = harness.snapshot.episode
        harness.send(.reset(.systemWake, at: instant(8)))
        #expect(harness.presence == .unknown(.reset(.systemWake)))
        #expect(harness.presenceSteps.last == Step("unknown(reset:systemWake)", .reset(.systemWake)))
        #expect(harness.snapshot.episode.raw == before.raw + 1)
        #expect(harness.snapshot.evidence == .none)
    }

    @Test("unknown → unknown is a non-transition: it reports uncertainty instead")
    func unknownGraceIsNotATransition() {
        var harness = Harness()
        harness.observe(nearRSSI, at: 1)
        harness.tick(20)
        #expect(!harness.snapshot.presenceUncertain)
        harness.tick(31)
        #expect(harness.snapshot.presenceUncertain, "unknownGrace elapsed with fewer than minSamples")
        #expect(harness.presenceTransitions.isEmpty)
        #expect(harness.presence == .unknown(.initial))
    }

    @Test("every presence transition increments the episode")
    func episodeIncrementsOnEveryPresenceTransition() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 20)
        harness.drive(nearRSSI, from: 21, through: 31)
        #expect(harness.presenceTransitions.count == 4)
        #expect(harness.snapshot.episode.raw == 4)
    }

    @Test("device axis reports silence and recovery independently of presence")
    func deviceAxisTransitions() {
        var harness = harnessAtPresent()
        harness.tick(17)
        harness.observe(nearRSSI, at: 18)
        let deviceSteps = harness.transitions(on: .device(DeviceID("device-A")))
            .map { Step($0.to, $0.cause) }
        #expect(deviceSteps == [Step("silent", .deviceSilent), Step("receiving", .deviceReceiving)])
    }
}

@Suite("ProximityEngine — regressions")
struct ProximityEngineRegressionTests {
    /// T-01: the `-20` spike must not produce a presence transition.
    @Test func t01_spikeDoesNotConfirmPresence() {
        var harness = Harness()
        for (index, rssi) in [-62, -61, -20, -63, -64].enumerated() {
            harness.observe(rssi, at: Double(index))
        }
        harness.tick(6)
        harness.tick(9)
        #expect(harness.presenceTransitions.isEmpty)
        #expect(harness.presence == .unknown(.initial))
        let fused = harness.snapshot.fusedScore ?? 1
        #expect(fused < EngineConfiguration().enterThreshold)
    }

    /// T-02: forward and reverse presence paths over one continuous recording.
    @Test func t02_forwardAndReversePaths() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 20)
        harness.drive(nearRSSI, from: 21, through: 31)
        #expect(harness.presenceSteps == [
            Step("present", .confirmedNear),
            Step("departing", .signalWeakened),
            Step("away", .measuredFar),
            Step("present", .confirmedNear),
        ])
    }

    /// T-03: a failed scanner is a sensor fact, never an absence fact.
    @Test func t03_sensorUnavailableNeverYieldsAway() {
        var harness = harnessAtPresent()
        harness.send(.sensor(.unavailable(.poweredOff), at: instant(7)))
        for t in [17.0, 40, 80, 120, 200] { harness.tick(t) }

        #expect(harness.presence == .present, "presence keeps its last known value while the sensor is down")
        #expect(!harness.presenceSteps.contains { $0.to == "away" })
        #expect(harness.snapshot.sensor == .unavailable(.poweredOff))

        let sensorSteps = harness.transitions(on: .sensor).map { Step($0.to, $0.cause) }
        #expect(sensorSteps == [
            Step("healthy", .sensorBecameHealthy),
            Step("unavailable(poweredOff)", .sensorUnavailable(.poweredOff)),
        ])
    }

    @Test func sensorRestoreReturnsPresenceToUnknown() {
        var harness = harnessAtPresent()
        harness.send(.sensor(.degraded(.scanInterrupted), at: instant(7)))
        #expect(harness.presence == .present)
        harness.send(.sensor(.available, at: instant(9)))
        #expect(harness.presence == .unknown(.sensorRestored))
        #expect(harness.presenceSteps.last == Step("unknown(sensorRestored)", .sensorRestored))
        #expect(harness.snapshot.evidence == .none)
    }

    @Test func sensorRecoveryFromUnavailablePassesThroughInitializing() {
        var harness = Harness(sensorAvailableAt: nil)
        #expect(harness.snapshot.sensor == .initializing)
        harness.send(.sensor(.unavailable(.poweredOff), at: instant(0)))
        harness.send(.sensor(.available, at: instant(1)))
        let sensorSteps = harness.transitions(on: .sensor).map { Step($0.to, $0.cause) }
        #expect(sensorSteps == [
            Step("unavailable(poweredOff)", .sensorUnavailable(.poweredOff)),
            Step("initializing", .sensorInitializing),
            Step("healthy", .sensorBecameHealthy),
        ])
    }

    @Test func initialSensorStartupDoesNotDisturbPresence() {
        // initializing → healthy at startup is not a *restore*: presence is already unknown(.initial)
        // and must not be churned into unknown(.sensorRestored).
        var harness = Harness(sensorAvailableAt: nil)
        harness.send(.sensor(.available, at: instant(0)))
        #expect(harness.presenceTransitions.isEmpty)
        #expect(harness.presence == .unknown(.initial))
    }

    /// T-08: nothing an attacker or a noisy room can do within 3 s of a wake reaches a decision.
    @Test func t08_nothingIsDecidableWithinThreeSecondsOfAWake() {
        var harness = harnessAtPresent()
        harness.send(.reset(.systemWake, at: instant(10)))
        let baseline = harness.presenceTransitions.count

        // 3000 samples in the first 3 s, alternating between very near and very far.
        var t = 10.0
        var index = 0
        while t < 13.0 {
            harness.observe(index % 2 == 0 ? nearRSSI : -30, at: t)
            harness.tick(t)
            t += 0.001
            index += 1
        }
        #expect(harness.presence == .unknown(.reset(.systemWake)))
        #expect(harness.presenceTransitions.count == baseline)
        // The very next second, with the confirm duration finally satisfied, it can decide.
        harness.observe(nearRSSI, at: 13.1)
        #expect(harness.presence == .present)
    }

    /// T-13: sudden silence at the desk is lost evidence, never departure.
    @Test func t13_suddenSilenceYieldsEvidenceExpiredNotAway() {
        var harness = harnessAtPresent()
        for t in [17.0, 20, 25, 30, 35] { harness.tick(t) }
        #expect(harness.presence == .present, "recency decay alone must never produce departing or away")
        harness.tick(36)
        #expect(harness.presenceSteps.last == Step("unknown(evidenceExpired)", .evidenceExpired))
        #expect(harness.snapshot.evidence == .none)
        #expect(!harness.presenceSteps.contains { $0.to == "away" || $0.to == "departing" })
    }

    /// T-14: weakening then silence is stronger absence evidence, and is labelled as such.
    @Test func t14_departingThenSilentYieldsAwayWithProvenance() {
        var harness = harnessAtPresent()
        harness.drive(farRSSI, from: 7, through: 13)
        #expect(harness.presence == .departing)
        harness.tick(24)
        #expect(harness.presenceSteps.last == Step("away", .departureThenSilent))
        #expect(harness.snapshot.evidence == .departureThenSilent)
    }

    @Test func t14_departingThenSilentWithoutTheWeakPreludeExpiresInstead() {
        var harness = harnessAtPresent()
        // Silence starts at the very moment departing is entered, so the last three measured
        // fused values are not all below exit: this is lost evidence, not a departure.
        harness.drive(farRSSI, from: 7, through: 10)
        #expect(harness.presence == .departing)
        harness.tick(21)
        #expect(harness.presence == .departing)
        harness.tick(41)
        #expect(harness.presenceSteps.last == Step("unknown(evidenceExpired)", .evidenceExpired))
        #expect(harness.snapshot.evidence == .none)
    }
}

@Suite("ProximityEngine — deadlines, reset, gate")
struct ProximityEngineMechanicsTests {
    @Test func noDeadlineBeforeAnyInput() {
        let engine = ProximityEngine(devices: [DeviceID("device-A")], gate: .armed(testProfile))
        #expect(engine.snapshot.nextDeadline == nil)
        #expect(engine.snapshot.presence == .unknown(.initial))
        #expect(engine.snapshot.episode.raw == 0)
    }

    @Test func deadlineIsTheEarliestPendingTimer() {
        var harness = harnessAtPresent()
        // Pending: device silence at 6+10, evidence expiry at 6+30.
        #expect(harness.snapshot.nextDeadline == instant(16))
        harness.tick(17)
        #expect(harness.snapshot.nextDeadline == instant(36), "silence fired; evidence expiry is next")
    }

    @Test func deadlineIsNilWhenNothingIsPending() {
        var harness = harnessAtPresent()
        harness.tick(36)
        #expect(harness.presence == .unknown(.evidenceExpired))
        harness.tick(100)
        #expect(harness.snapshot.nextDeadline == nil)
    }

    @Test func deadlineNeverPrecedesTheLastInput() {
        var harness = harnessAtPresent()
        for t in stride(from: 7.0, through: 60.0, by: 0.5) {
            harness.tick(t)
            if let deadline = harness.snapshot.nextDeadline {
                #expect(deadline > instant(t))
            }
        }
    }

    @Test func earlyTicksAreHarmless() {
        var harness = Harness()
        for t in stride(from: 0.0, through: 5.0, by: 0.1) { harness.tick(t) }
        #expect(harness.presenceTransitions.isEmpty)
        harness.drive(nearRSSI, from: 6, through: 12)
        #expect(harness.presence == .present)
    }

    @Test func ticksEarlierThanTheLastInputAreIgnored() {
        var harness = harnessAtPresent()
        let deadline = harness.snapshot.nextDeadline
        #expect(harness.send(.tick(at: instant(3))).isEmpty)
        #expect(harness.snapshot.nextDeadline == deadline)
        #expect(harness.presence == .present)
    }

    @Test func resetClearsTracksAndKeepsTheGate() {
        var harness = harnessAtPresent()
        #expect(harness.snapshot.devices[DeviceID("device-A")]?.estimate != nil)
        harness.send(.reset(.bluetoothReset, at: instant(9)))
        let track = harness.snapshot.devices[DeviceID("device-A")]
        #expect(track?.estimate == nil)
        #expect(track?.score == nil)
        #expect(track?.observation == .receiving)
        #expect(track?.isCalibrated == true, "the calibration gate survives a reset")
        #expect(harness.snapshot.fusedScore == nil)
    }

    @Test func resetRequiresTheFullEvidenceBudgetAgain() {
        var harness = harnessAtPresent()
        harness.send(.reset(.devicesChanged, at: instant(9)))
        harness.drive(nearRSSI, from: 10, through: 14)
        #expect(harness.presence == .unknown(.reset(.devicesChanged)))
        harness.observe(nearRSSI, at: 16)
        #expect(harness.presence == .present)
    }

    @Test func updateGateDoesNotResetPresence() {
        var harness = harnessAtPresent()
        let episode = harness.snapshot.episode
        harness.engine.update(gate: .notArmed(.macMismatch))
        #expect(harness.presence == .present)
        #expect(harness.snapshot.episode == episode)
        #expect(harness.presenceTransitions.count == 1)
    }

    @Test func notArmedGateMarksTracksUncalibrated() {
        var harness = Harness(gate: .notArmed(.noProfile))
        harness.drive(nearRSSI, from: 0, through: 6)
        let track = harness.snapshot.devices[DeviceID("device-A")]
        #expect(track?.isCalibrated == false)
        #expect(track?.score != nil, "scoring continues for display; only Policy is gated")
        harness.engine.update(gate: .armed(testProfile))
        #expect(harness.snapshot.devices[DeviceID("device-A")]?.isCalibrated == true)
    }

    @Test func rejectedObservationsDoNotFeedThePipeline() {
        var harness = Harness()
        harness.drive(nearRSSI, from: 0, through: 6)
        let before = harness.snapshot.devices[DeviceID("device-A")]?.estimate
        harness.observe(50, at: 7)                                  // out of range
        harness.observe(nearRSSI, at: 7, device: "device-Z")        // unknown device
        let after = harness.snapshot.devices[DeviceID("device-A")]?.estimate
        #expect(before?.smoothedRSSI == after?.smoothedRSSI)
        #expect(before?.sampleCount == after?.sampleCount)
        #expect(harness.snapshot.devices[DeviceID("device-Z")] == nil)
    }

    /// proximity-domain.md §1.1 note: the reorder reference is the newest accepted instant and does
    /// not move backwards, so a run of reordered samples cannot walk the skew window backwards.
    @Test func aReorderWithinSkewDoesNotRewindTheReference() {
        var harness = Harness()
        harness.observe(nearRSSI, at: 10)
        harness.observe(nearRSSI, at: 9.5)          // inside maxSkew of the 10 s sample: accepted
        #expect(harness.snapshot.devices[DeviceID("device-A")]?.estimate?.sampleCount == 2)

        // Still judged against 10 s rather than 9.5 s, so this one falls outside the window.
        harness.observe(nearRSSI, at: 8.6)
        let track = harness.snapshot.devices[DeviceID("device-A")]
        #expect(track?.estimate?.sampleCount == 2)
        #expect(track?.estimate?.lastSeen == instant(10), "an accepted reorder does not rewind last-seen")
    }

    @Test func aResetClearsTheReorderReference() {
        var harness = Harness()
        harness.observe(nearRSSI, at: 10)
        harness.send(.reset(.systemWake, at: instant(10)))
        // A sample queued from before the wake is accepted, since the new episode has no reference
        // yet, but it is clamped to the reset instant so it cannot backdate the new evidence.
        harness.observe(nearRSSI, at: 5)
        let track = harness.snapshot.devices[DeviceID("device-A")]
        #expect(track?.estimate?.sampleCount == 1)
        #expect(track?.estimate?.lastSeen == instant(10))
    }
    @Test func multipleDevicesFuseByMaximumAndSilenceIsPerDevice() {
        var harness = Harness(devices: ["device-A", "device-B"])
        for second in stride(from: 0.0, through: 6.0, by: 1) {
            harness.observe(farRSSI, at: second, device: "device-A")
            harness.observe(nearRSSI, at: second, device: "device-B")
        }
        #expect(harness.presence == .present, "the nearest receiving device wins")
        harness.drive(nearRSSI, from: 7, through: 30, device: "device-B")
        #expect(harness.snapshot.devices[DeviceID("device-A")]?.observation != .receiving)
        #expect(harness.presence == .present, "one silent device does not expire the evidence")
    }
}
