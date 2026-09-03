import Foundation
import ThresholdBluetooth
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem

/// The user-facing writes: settings and the trusted-device registry.
///
/// Every one of them follows the same three steps — change the in-memory value, persist it,
/// tell the Coordinator — in that order. Persisting before notifying is deliberate: the
/// Coordinator acts on what it is told, so it must never be running on a value that a relaunch
/// would disagree with.
extension AppContainer {

    // MARK: - Settings

    /// Applies a change to `PolicySettings`, persists it, and reports a save failure.
    ///
    /// The in-memory value is updated even when the write fails, because refusing the toggle
    /// the user just moved is more confusing than a switch that works now and warns that it
    /// will not survive a relaunch. The Coordinator is told either way, so what the switch says
    /// and what the pipeline does never disagree within a session.
    public func updateSettings(_ transform: (inout PolicySettings) -> Void) {
        var settings = model.settings
        transform(&settings)
        guard settings != model.settings else { return }
        model.settings = settings
        do {
            try settingsStore.save(settings)
        } catch {
            model.startupIssues.append(StoreErrorText.describe(error))
        }
        // `effectiveSettings`, not `settings`: a change made while calibrating still has both
        // automatic actions forced off until the run ends (see `effectiveSettings`).
        send(.settingsChanged(effectiveSettings))
    }

    public func setAutoLock(_ enabled: Bool) { updateSettings { $0.autoLock = enabled } }
    public func setWakeOnReturn(_ enabled: Bool) { updateSettings { $0.wakeOnReturn = enabled } }
    public func setLockOnDepartureThenSilent(_ enabled: Bool) {
        updateSettings { $0.lockOnDepartureThenSilent = enabled }
    }
    public func setSilenceLock(_ policy: SilenceLockPolicy) { updateSettings { $0.silenceLock = policy } }

    // MARK: - Devices

    /// Adds or renames a trusted device and rearms scanning around the new set.
    public func registerDevice(_ device: RegisteredDevice) throws {
        let registry = model.registry.adding(device)
        try persist(registry: registry)
        armScanning()
    }

    public func renameDevice(_ id: DeviceID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try persist(registry: model.registry.renaming(id, to: trimmed))
    }

    /// Removes a trusted device **and** its calibration.
    ///
    /// The calibration goes with it deliberately. A profile is a measurement of one device's
    /// signal in one room on one Mac; keeping it after the device is gone means that
    /// re-adding a device with the same identifier later would silently arm automation on a
    /// months-old measurement the user never re-took.
    public func removeDevice(_ id: DeviceID) throws {
        try persist(registry: model.registry.removing(id))
        let remaining = calibrationRecords.filter { $0.device != id }
        if remaining.count != calibrationRecords.count {
            let previous = calibrationRecords
            calibrationRecords = remaining
            do {
                try calibrationStore.save(remaining)
            } catch {
                calibrationRecords = previous
                publishGate()
                throw error
            }
        }
        publishGate()
        needsOnboarding = model.registry.isEmpty
        armScanning()
    }

    /// Discards every stored calibration, leaving trusted devices registered.
    public func resetCalibration() throws {
        let previous = calibrationRecords
        calibrationRecords = []
        do {
            try calibrationStore.save([])
        } catch {
            calibrationRecords = previous
            throw error
        }
        publishGate()
    }

    /// Writes the registry and recomputes the gate around it.
    ///
    /// The gate is published before the caller's `armScanning()` sends `.devicesChanged`, and
    /// the input stream preserves that order, so the engine the Coordinator rebuilds for the
    /// new device set is built with the new gate rather than the previous one.
    func persist(registry: DeviceRegistry) throws {
        let records = registry.devices.map { DeviceRecord(device: $0.id, name: $0.name) }
        try deviceStore.save(records)
        model.registry = registry
        publishGate()
    }
}
