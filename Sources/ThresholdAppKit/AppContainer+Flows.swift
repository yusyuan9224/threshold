import ThresholdBluetooth
import ThresholdDomain
import ThresholdRuntime

/// Onboarding and calibration, which are the two places the App layer drives the scanner
/// directly rather than through the Coordinator.
///
/// Both are interactive, short-lived and outside the monitoring pipeline: discovery results
/// never become `BLEObservation`s (bluetooth.md §2), and calibration samples go to a
/// `CalibrationSession`, not to the presence engine. Keeping them in the container rather than
/// in a view is what stops a SwiftUI body from owning a `Task` that outlives the window.
extension AppContainer: OnboardingActions {

    // MARK: - Onboarding

    /// Creates (or returns) the onboarding flow.
    public func makeOnboardingFlow() -> OnboardingFlow {
        if let onboarding { return onboarding }
        let flow = OnboardingFlow(actions: self)
        onboarding = flow
        return flow
    }

    /// Starts a discovery session and pumps it into the flow.
    ///
    /// This is where the Bluetooth permission prompt appears, because it is the first time
    /// `CBCentralManager` is created. It happens on an explicit button press on a screen that
    /// has already explained why, which is the whole reason scanning is deferred at launch
    /// (architecture.md §5.4, system-integration.md §6).
    public func startDiscovery() {
        discoveryTask?.cancel()
        let stream = scanner.discover()
        discoveryTask = Task { [weak self] in
            for await device in stream {
                guard let self else { return }
                self.onboarding?.discovered(device)
            }
        }
    }

    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        scanner.stopDiscovery()
    }

    public func completeOnboarding() {
        stopDiscovery()
        needsOnboarding = model.registry.isEmpty
        onboarding = nil
    }

    /// Reopens onboarding from the menu ("Set up device…"), even when a device already exists.
    public func presentOnboarding() {
        needsOnboarding = true
        _ = makeOnboardingFlow()
    }

    /// Opens onboarding straight at the calibration step ("Calibrate…" in the menu).
    ///
    /// Does nothing without a trusted device: there is nothing to measure, and dropping the
    /// user into a progress bar that can never fill would be worse than a disabled button.
    public func presentCalibrationOnboarding() {
        guard !model.registry.isEmpty else { return }
        needsOnboarding = true
        makeOnboardingFlow().jumpToCalibration()
    }

    // MARK: - Calibration

    /// Starts a calibration run for one device and feeds it the scanner's observations.
    ///
    /// Scanning is narrowed to the single device being calibrated: `startScanning(for:)` is
    /// the filter, so no other trusted device's advertisements can land in the session and
    /// blur the baselines.
    ///
    /// **The Coordinator keeps running, and must not act.** A calibration run is the user
    /// deliberately walking away from their Mac and back; to the presence engine that is
    /// indistinguishable from a departure, and left alone it would lock the screen in the
    /// middle of a measurement. Both automatic actions are therefore forced off for the
    /// duration by sending `effectiveSettings` — the fail-closed choice, and one the engine
    /// needs to know nothing about. They come back when `endCalibration()` sends the settings
    /// again, derived from `model.settings` as it stands *then*, so a change the user made in
    /// the Settings window while calibrating is not undone.
    ///
    /// The samples come from `tee.openCalibrationTap()` rather than `scanner.observations`,
    /// which the Coordinator is already iterating; see `ObservationTee` for why sharing that
    /// one property between the two would halve both.
    @discardableResult
    public func beginCalibration(device: DeviceID) -> CalibrationFlow {
        endCalibration(restoreScanning: false)
        let flow = CalibrationFlow(device: device, policy: calibrationPolicy)
        calibration = flow
        scanner.startScanning(for: [device])
        send(.settingsChanged(effectiveSettings))
        let stream = tee.openCalibrationTap()
        calibrationTask = Task { [weak self] in
            for await observation in stream {
                guard let self else { return }
                self.calibration?.ingest(observation)
            }
        }
        return flow
    }

    /// Ends the run, resets the pipeline, and puts the user's settings back.
    ///
    /// `armScanning()` also sends `.devicesChanged`, which makes the Coordinator rebuild its
    /// engines and reset presence. That is the point: whatever belief it formed while the scan
    /// was narrowed to one device being carried around the room is discarded rather than
    /// carried into normal operation, and presence has to be earned again from fresh samples.
    ///
    /// **Reset first, re-enable second.** A calibration run ends with the engine believing the
    /// user is `away`, because the second half of the measurement is them standing across the
    /// room. Restoring Auto Lock before discarding that belief would lock the screen the instant
    /// the run finished — in front of a user who is sitting back down. The input stream keeps
    /// the two in the order they are sent, so this ordering is the whole fix.
    public func endCalibration(restoreScanning: Bool = true) {
        calibrationTask?.cancel()
        calibrationTask = nil
        tee.closeCalibrationTap()
        let wasCalibrating = calibration != nil
        calibration = nil
        if restoreScanning { armScanning() }
        if wasCalibrating { send(.settingsChanged(effectiveSettings)) }
    }

    /// Persists a finished calibration, replacing any previous record for the same device, and
    /// recomputes the gate.
    ///
    /// One record per device: a second profile for the same device is a *re*calibration, and
    /// keeping both would leave `CalibrationValidator.gate` picking whichever the array
    /// happened to list first.
    public func applyCalibration(_ record: CalibrationRecord) throws {
        let previous = calibrationRecords
        var records = previous.filter { $0.device != record.device }
        records.append(record)
        calibrationRecords = records
        do {
            try calibrationStore.save(records)
        } catch {
            calibrationRecords = previous
            publishGate()
            throw error
        }
        publishGate()
    }
}
