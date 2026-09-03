import Testing
import ThresholdBluetooth
import ThresholdDomain
@testable import ThresholdAppKit

/// `ProtectionStatus` is the sentence a user reads to decide whether their Mac is looking
/// after itself, so every branch is pinned here — including the order the branches are
/// checked in, which is what stops a real fault being masked by a cosmetic one.
@MainActor
@Suite struct AppModelProtectionStatusTests {

    private func armedModel() -> AppModel {
        let model = AppModel(
            registry: DeviceRegistry(devices: [RegisteredDevice(id: Fixtures.deviceA, name: "Phone")]),
            calibrationGate: .armed(Fixtures.profile)
        )
        model.receive(sensor: .healthy)
        return model
    }

    @Test func noTrustedDeviceIsNotArmedRatherThanPaused() {
        let model = AppModel()
        #expect(model.protectionStatus == .notArmed(reason: "set up a trusted device"))
    }

    @Test func initializingSensorIsNeitherActiveNorPaused() {
        let model = AppModel(
            registry: DeviceRegistry(devices: [RegisteredDevice(id: Fixtures.deviceA, name: "Phone")]),
            calibrationGate: .armed(Fixtures.profile)
        )
        #expect(model.sensorHealth == .initializing)
        #expect(model.protectionStatus == .initializing)
    }

    @Test func healthySensorAndArmedGateIsActive() {
        #expect(armedModel().protectionStatus == .active)
    }

    /// security.md §2 rule 2: a non-healthy sensor stops automation, and the UI must say so.
    @Test(arguments: [
        SensorHealth.unavailable(.poweredOff),
        .unavailable(.unauthorized),
        .unavailable(.unsupported),
        .unavailable(.scannerFailed),
        .degraded(.resetting),
        .degraded(.scanInterrupted),
    ])
    func anyUnhealthySensorPauses(_ health: SensorHealth) {
        let model = armedModel()
        model.receive(sensor: health)
        guard case .paused = model.protectionStatus else {
            Issue.record("expected paused for \(health), got \(model.protectionStatus)")
            return
        }
        #expect(model.degradedBanner?.hasPrefix("Bluetooth unavailable — automatic protection is paused.") == true)
    }

    /// A sensor fault must not be reported as "not armed: calibrate", which would send the
    /// user to do 40 seconds of measurement that cannot possibly help.
    @Test func sensorFaultOutranksAnUnarmedGate() {
        let model = AppModel(registry: DeviceRegistry(devices: [RegisteredDevice(id: Fixtures.deviceA, name: "Phone")]))
        model.receive(sensor: .unavailable(.poweredOff))
        #expect(model.calibrationGate == .notArmed(.noProfile))
        #expect(model.protectionStatus == .paused(reason: "Bluetooth is turned off"))
    }

    /// security.md §2 rule 4.
    @Test func unarmedCalibrationBlocksEvenWithAHealthySensor() {
        let model = AppModel(registry: DeviceRegistry(devices: [RegisteredDevice(id: Fixtures.deviceA, name: "Phone")]))
        model.receive(sensor: .healthy)
        #expect(model.protectionStatus == .notArmed(reason: PlainLanguage.notArmed(.noProfile)))
    }

    @Test func bothSwitchesOffReadsAsPaused() {
        let model = armedModel()
        var settings = PolicySettings()
        settings.autoLock = false
        settings.wakeOnReturn = false
        model.settings = settings
        #expect(model.protectionStatus == .paused(reason: "both automatic actions are turned off in Settings"))
    }

    @Test func oneSwitchOnStillCountsAsActive() {
        let model = armedModel()
        var settings = PolicySettings()
        settings.autoLock = false
        model.settings = settings
        #expect(model.protectionStatus == .active)
    }

    @Test func onlyAnUnauthorizedOrOffRadioOffersASettingsShortcut() {
        let model = armedModel()
        model.receive(sensor: .unavailable(.unauthorized))
        #expect(model.bluetoothRemedy == .openPrivacySettings)
        model.receive(sensor: .unavailable(.poweredOff))
        #expect(model.bluetoothRemedy == .openBluetoothSettings)
        model.receive(sensor: .unavailable(.unsupported))
        #expect(model.bluetoothRemedy == nil)
        model.receive(sensor: .healthy)
        #expect(model.bluetoothRemedy == nil)
        #expect(model.degradedBanner == nil)
    }
}

/// ADR-008 says the absence of evidence is not evidence of absence. These assertions keep that
/// promise at the last place it can be broken: the words on screen.
@MainActor
@Suite struct PresenceWordingTests {

    @Test func silenceIsNeverRenderedAsAbsence() {
        let quiet = PlainLanguage.presence(.unknown(.evidenceExpired))
        #expect(!quiet.lowercased().contains("away"))
        #expect(quiet.contains("quiet"))
    }

    @Test func initialStateIsNotRenderedAsPresence() {
        let initial = PlainLanguage.presence(.unknown(.initial))
        #expect(!initial.lowercased().contains("at your mac"))
    }

    @Test func departureThenSilentIsNotDescribedAsConfirmedDeparture() {
        let text = PlainLanguage.evidence(.departureThenSilent)
        #expect(text.contains("silent"))
        #expect(!text.lowercased().contains("confirmed"))
    }

    /// A radio fact is not a user fact. The model mirrors whatever presence the engine put in
    /// the snapshot and never derives one from the sensor axis — the exact conflation ADR-008
    /// forbids, and the one the Coordinator's `sensorRestored` reset exists to make explicit.
    @Test func sensorHealthNeverMovesThePresenceAxis() {
        let model = AppModel()
        model.receive(sensor: .healthy)
        #expect(model.presence == .unknown(.initial))
        #expect(model.sensorHealth == .healthy)
        model.receive(sensor: .unavailable(.poweredOff))
        #expect(model.presence == .unknown(.initial))
        #expect(model.evidence == .none)
    }

    @Test func snapshotDrivesPresenceEvidenceAndSensorTogether() {
        let model = AppModel()
        let snapshot = ProximitySnapshot(
            presence: .away,
            presenceSince: Fixtures.instant(seconds: 10),
            episode: EpisodeID(3),
            evidence: .measuredFar,
            lastTransition: .measuredFar,
            sensor: .healthy,
            devices: [:],
            nextDeadline: nil
        )
        model.snapshotUpdated(snapshot)
        #expect(model.presence == .away)
        #expect(model.evidence == .measuredFar)
        #expect(model.sensorHealth == .healthy)
    }
}
