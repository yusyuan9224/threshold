import ThresholdBluetooth
import ThresholdDomain

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
    @discardableResult
    public func beginCalibration(device: DeviceID) -> CalibrationFlow {
        endCalibration(restoreScanning: false)
        let flow = CalibrationFlow(device: device, policy: calibrationPolicy)
        calibration = flow
        scanner.startScanning(for: [device])
        let stream = scanner.observations
        calibrationTask = Task { [weak self] in
            for await observation in stream {
                guard let self else { return }
                self.calibration?.ingest(observation)
            }
        }
        return flow
    }

    /// Ends the run and puts scanning back the way it was.
    public func endCalibration(restoreScanning: Bool = true) {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibration = nil
        if restoreScanning { armScanning() }
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
            model.calibrationGate = currentGate()
            throw error
        }
        model.calibrationGate = currentGate()
    }
}
