import Testing
@testable import ThresholdDomain

@Suite("L2 fixture replay (testing.md §1, §3)")
struct FixtureReplayTests {
    /// The regression gate: every recording must still produce exactly the presence transitions
    /// recorded in its golden file. Any engine change that moves one of these has to say so.
    @Test(arguments: Fixtures.names)
    func replayMatchesGolden(_ name: String) throws {
        let replayed = try Fixtures.replay(name)
        let golden = try Fixtures.golden(name)
        #expect(replayed.scenario == golden.scenario)
        #expect(replayed.transitions == golden.transitions)
        #expect(replayed.final == golden.final)
    }

    @Test(arguments: Fixtures.names)
    func replayIsDeterministic(_ name: String) throws {
        #expect(try Fixtures.replay(name) == Fixtures.replay(name))
    }

    @Test func everyRequiredScenarioIsPresent() throws {
        // Also the guard on the directory scan: if the bundle went missing, `names` would be empty
        // and every parameterised test in this suite would vacuously pass.
        #expect(!Fixtures.names.isEmpty)
        for scenario in Fixtures.requiredScenarios {
            #expect(Fixtures.names.contains(scenario), "missing required fixture \(scenario)")
        }
    }

    @Test func bundleResourcesResolve() throws {
        let directory = try Fixtures.directory()
        for name in Fixtures.names {
            #expect(try Fixtures.url(name, extension: "jsonl").path.hasPrefix(directory.path))
            _ = try Fixtures.load(name)
            _ = try Fixtures.golden(name)
        }
    }

    @Test(arguments: Fixtures.names)
    func metadataIsAnonymisedAndComplete(_ name: String) throws {
        let meta = try Fixtures.load(name).meta
        #expect(meta.kind == "meta")
        // The filename is the scenario: a capture dropped in as `desk-1m.jsonl` must say
        // `"scenario":"desk-1m"`, so a golden can never be matched against the wrong recording.
        #expect(meta.scenario == name)
        #expect(meta.anonymized)
        #expect(["laptop", "desktop"].contains(meta.macClass))
        #expect(["iphone", "watch", "beacon"].contains(meta.deviceClass))
        #expect(!meta.recorder.isEmpty)
    }

    @Test(arguments: Fixtures.names)
    func deviceNamesAreAnonymised(_ name: String) throws {
        // `device-A`, `device-B`, … assigned in capture order. Anything longer is a name, a serial
        // or an identifier that should never have reached a fixture.
        for case .observation(let observation) in try Fixtures.load(name).inputs {
            let alias = observation.device.raw
            #expect(alias.hasPrefix("device-"))
            let suffix = alias.dropFirst("device-".count)
            #expect(!suffix.isEmpty && suffix.count <= 2)
            #expect(suffix.allSatisfy { $0.isLetter && $0.isUppercase })
        }
    }

    /// The three fixtures that exist to prove a negative: silence and sensor failure are not
    /// departure, whatever else the recording contains.
    @Test(arguments: ["sudden-silence-at-desk", "device-lost", "bluetooth-off"])
    func lostEvidenceNeverBecomesAway(_ name: String) throws {
        let golden = try Fixtures.golden(name)
        #expect(!golden.transitions.contains { $0.to == "away" })
        #expect(golden.final.evidence != "measuredFar")
    }

    @Test func departureThenSilentKeepsItsProvenance() throws {
        let golden = try Fixtures.golden("departure-then-silent")
        #expect(golden.transitions.map(\.to) == ["present", "departing", "away"])
        #expect(golden.transitions.last?.cause == "departureThenSilent")
        #expect(golden.final.evidence == "departureThenSilent")
    }

    /// T-08 at fixture scale: the wake reset lands at 12 s and presence cannot return before 15 s.
    @Test func wakeAfterSleepCannotLockOnWithinThreeSeconds() throws {
        let golden = try Fixtures.golden("wake-after-sleep")
        guard let reset = golden.transitions.first(where: { $0.cause == "reset(systemWake)" }),
              let recovery = golden.transitions.last else {
            Issue.record("wake-after-sleep must contain a reset and a recovery")
            return
        }
        #expect(recovery.to == "present")
        #expect(recovery.at - reset.at >= 3_000)
    }

    /// T-01 at fixture scale.
    @Test func aSingleSpikeChangesNothing() throws {
        let golden = try Fixtures.golden("signal-spike")
        #expect(golden.transitions.count == 1)
        #expect(golden.transitions.first?.to == "present")
    }

    @Test func noisyEnvironmentDoesNotProduceSpuriousDepartures() throws {
        let golden = try Fixtures.golden("wifi-interference")
        #expect(!golden.transitions.contains { $0.to == "departing" || $0.to == "away" })
        #expect(golden.final.presence == "present")
    }
}
