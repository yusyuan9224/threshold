import Foundation
import Testing
import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem
@testable import ThresholdAppKit

/// Records what `OnboardingFlow` asked the rest of the app to do.
@MainActor
final class SpyOnboardingActions: OnboardingActions {
    private(set) var startDiscoveryCount = 0
    private(set) var stopDiscoveryCount = 0
    private(set) var registered: [RegisteredDevice] = []
    private(set) var completeCount = 0
    var registerFailure: (any Error)?

    func startDiscovery() { startDiscoveryCount += 1 }
    func stopDiscovery() { stopDiscoveryCount += 1 }
    func completeOnboarding() { completeCount += 1 }

    func registerDevice(_ device: RegisteredDevice) throws {
        if let registerFailure { throw registerFailure }
        registered.append(device)
    }
}

enum Fixtures {
    static let deviceA = DeviceID("device-A")
    static let deviceB = DeviceID("device-B")

    static func instant(seconds: Int64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
    }

    static func discovered(_ id: DeviceID, name: String?, rssi: Int, atSecond: Int64) -> DiscoveredDevice {
        DiscoveredDevice(id: id, advertisedName: name, rssi: rssi, at: instant(seconds: atSecond))
    }

    static func observation(_ id: DeviceID, rssi: Int, atSecond: Int64) -> BLEObservation {
        BLEObservation(device: id, at: instant(seconds: atSecond), rssi: rssi)
    }

    /// A profile that is self-consistent and, crucially, not `CalibrationProfile.default` —
    /// `CalibrationValidator` treats the default as a placeholder and refuses to arm on it.
    static let profile = CalibrationProfile(nearBaseline: -50, farBaseline: -80, noise: 1, midpoint: -65, slope: 7.5)

    static func record(
        device: DeviceID = deviceA,
        macIdentity: String = "test-mac",
        osMajorVersion: Int = 26,
        profile: CalibrationProfile = Fixtures.profile
    ) -> CalibrationRecord {
        CalibrationRecord(
            device: device,
            macIdentity: macIdentity,
            profile: profile,
            osMajorVersion: osMajorVersion,
            appVersion: "test",
            createdAtUnixSeconds: 1_000
        )
    }

    /// A `ProximitySnapshot` with one axis under test and the rest left at their initial
    /// values, so a test about the sensor axis cannot accidentally assert about presence.
    static func snapshot(
        presence: PresenceState = .unknown(.initial),
        evidence: PresenceEvidence = .none,
        sensor: SensorHealth,
        lastTransition: TransitionCause? = nil,
        atSecond: Int64 = 0
    ) -> ProximitySnapshot {
        ProximitySnapshot(
            presence: presence,
            presenceSince: instant(seconds: atSecond),
            episode: EpisodeID(1),
            evidence: evidence,
            lastTransition: lastTransition,
            sensor: sensor,
            devices: [:],
            nextDeadline: nil
        )
    }

    /// Alternating values one second apart: enough samples and enough span to clear
    /// `CalibrationPolicy`'s 15-sample / 20-second minimums, with a MAD of 0.5 dB.
    static func steadySamples(centre: Int, count: Int = 25, fromSecond: Int64 = 0) -> [(rssi: Int, second: Int64)] {
        (0..<count).map { index in
            (rssi: index.isMultiple(of: 2) ? centre : centre - 1, second: fromSecond + Int64(index))
        }
    }
}

@MainActor
extension AppModel {
    /// Drives the sensor axis the only way the app now can: through a whole snapshot.
    ///
    /// The model has no sensor-only entry point any more — sensor health reaches it folded
    /// into `snapshotUpdated`, which is what stops the status line and the presence line from
    /// ever describing two different moments.
    func receive(sensor: SensorHealth) {
        snapshotUpdated(Fixtures.snapshot(sensor: sensor))
    }
}

/// Spins the main actor until `condition` holds, so a test can wait on a `Task` that consumes
/// an `AsyncStream` without sleeping for a wall-clock interval.
///
/// Bounded on purpose: a condition that never becomes true fails the test rather than hanging
/// the suite.
@MainActor
func waitUntil(attempts: Int = 2_000, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
