import Testing
@testable import rssi_record

// The tool's first tests. `rssi-record` is the MAINTAINED recorder — the fixtures it writes are the
// engine's replay corpus and the SPIKE-009 evidence — but until now CI only checked that it built,
// which is how `--device-class ipad` stayed rejected while ADR-009 listed iPad as a supported class
// with an open evidence gap. A tool that cannot record a class the docs claim to support is a real
// defect, and it was invisible to `swift build`.
//
// Everything here is pure argument parsing: no CoreBluetooth, no filesystem, no clock.

/// A complete, valid argument list. Individual tests override one field at a time so a failure
/// names the field that broke rather than "parsing failed".
private func arguments(
    devices: [String] = ["11111111-1111-1111-1111-111111111111"],
    scenario: String = "desk-1m",
    macClass: String = "laptop",
    deviceClass: String = "iphone",
    seconds: String = "600",
    out: String = "desk-1m.jsonl"
) -> [String] {
    devices.flatMap { ["--device", $0] }
        + ["--scenario", scenario,
           "--mac-class", macClass,
           "--device-class", deviceClass,
           "--seconds", seconds,
           "--out", out]
}

@Suite("RecordOptions device classes")
struct RecordOptionsDeviceClassTests {
    /// The regression this file exists for. Driven off the allow-list itself rather than a literal
    /// list, so adding a class without teaching the parser about it cannot pass silently.
    @Test("every declared device class is accepted", arguments: RecordOptions.deviceClasses)
    func declaredClassIsAccepted(_ deviceClass: String) throws {
        let options = try RecordOptions.parse(arguments(deviceClass: deviceClass))
        #expect(options.deviceClass == deviceClass)
    }

    @Test("iPad is a recordable class")
    func iPadIsRecordable() throws {
        // Named explicitly, not just covered by the loop above: ADR-009 lists iPad as CONDITIONAL
        // with the distance matrix still open, so this is the class the tool most needs to accept.
        #expect(RecordOptions.deviceClasses.contains("ipad"))
        let options = try RecordOptions.parse(arguments(deviceClass: "ipad"))
        #expect(options.deviceClass == "ipad")
    }

    @Test("the list stays in sync with the fixture-replay assertion")
    func matchesFixtureReplayAllowList() {
        // `Tests/ThresholdDomainTests/FixtureReplayTests.metadataIsAnonymisedAndComplete` asserts
        // this same set from the other side. The two bundles cannot share a constant — the root
        // test bundle deliberately never links this package — so the list is pinned here, and this
        // test is the reminder to change both when it moves.
        #expect(RecordOptions.deviceClasses == ["iphone", "watch", "ipad", "beacon"])
    }

    @Test("an undeclared class is rejected, and the error names the flag")
    func undeclaredClassIsRejected() {
        do {
            _ = try RecordOptions.parse(arguments(deviceClass: "airpods"))
            Issue.record("expected an undeclared device class to be rejected")
        } catch let error as ToolError {
            // The operator is mid-experiment with a phone in the next room; the message has to say
            // what to type next, not just that something was wrong.
            #expect(error.description.contains("--device-class"))
            #expect(error.description.contains("ipad"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("an undeclared Mac class is rejected too")
    func undeclaredMacClassIsRejected() {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(macClass: "mini"))
        }
    }
}

@Suite("RecordOptions device identifiers")
struct RecordOptionsDeviceTests {
    @Test("at least one device is required")
    func atLeastOneDevice() {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(devices: []))
        }
    }

    @Test("the same device given twice is rejected")
    func duplicateDeviceIsRejected() {
        // Aliases are assigned by position (`device-A`, `device-B`, …), so a repeat would produce
        // two aliases for one radio and a fixture that reads as two devices.
        let uuid = "11111111-1111-1111-1111-111111111111"
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(devices: [uuid, uuid]))
        }
    }

    @Test("identifiers are canonicalised to uppercase")
    func identifiersAreCanonicalised() throws {
        // `CBPeripheral.identifier.uuidString` is uppercase; an operator pasting lowercase must
        // still match, or the recording silently observes nothing.
        let options = try RecordOptions.parse(
            arguments(devices: ["aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"])
        )
        #expect(options.devices.first?.uuidString == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    }

    @Test("a non-UUID device is rejected")
    func nonUUIDIsRejected() {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(devices: ["not-a-uuid"]))
        }
    }

    @Test("more devices than aliases is rejected")
    func tooManyDevicesRejected() {
        let uuids = (0..<(RecordOptions.maxDevices + 1)).map { index in
            String(format: "%08X-0000-0000-0000-000000000000", index)
        }
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(devices: uuids))
        }
    }
}

@Suite("RecordOptions scenario and duration")
struct RecordOptionsScenarioTests {
    @Test(
        "a scenario that could carry a device name is rejected",
        arguments: ["Desk-1m", "next room", "desk_1m", "-desk", "desk-", ""]
    )
    func unsafeScenarioIsRejected(_ scenario: String) {
        // The scenario is the only free-text field that reaches the fixture, so it is restricted
        // rather than escaped — an advertised name must not be able to ride in through it.
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(scenario: scenario))
        }
    }

    @Test("lowercase, digits and hyphens are accepted", arguments: ["desk-1m", "next-room-8m", "a"])
    func safeScenarioIsAccepted(_ scenario: String) throws {
        let options = try RecordOptions.parse(arguments(scenario: scenario))
        #expect(options.scenario == scenario)
    }

    @Test("duration must be within bounds", arguments: ["0", "-1", "abc", "86401"])
    func outOfRangeSecondsRejected(_ seconds: String) {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments(seconds: seconds))
        }
    }

    @Test("a full day is the longest allowed recording")
    func maxSecondsAccepted() throws {
        let options = try RecordOptions.parse(arguments(seconds: "\(RecordOptions.maxSeconds)"))
        #expect(options.seconds == 24 * 60 * 60)
    }
}

@Suite("RecordOptions flag handling")
struct RecordOptionsFlagTests {
    @Test("an unknown flag is rejected rather than ignored")
    func unknownFlagRejected() {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments() + ["--anonymise", "false"])
        }
    }

    @Test("a flag without a value is rejected")
    func danglingFlagRejected() {
        #expect(throws: ToolError.self) {
            try RecordOptions.parse(arguments() + ["--profile"])
        }
    }

    @Test("no calibration profile is a valid recording")
    func profileIsOptional() throws {
        // A capture taken before anyone has calibrated still parses; it just must never be given a
        // golden, because presence scoring is relative to midpoint and slope.
        let options = try RecordOptions.parse(arguments())
        #expect(options.profile == nil)
    }
}
