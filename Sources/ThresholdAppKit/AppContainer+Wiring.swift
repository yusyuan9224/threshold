import ThresholdBluetooth
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem

/// The two directions between the composition root and the `Coordinator` actor
/// (architecture.md §5): inputs out, events in.
///
/// Nothing here decides anything. Going out, a user action that changed a value the Coordinator
/// caches becomes one `CoordinatorInput`; coming in, one `CoordinatorEvent` becomes one call on
/// `AppEventSink`. Keeping both translations in one file is what makes it checkable that the
/// App layer is not quietly running a second, divergent copy of the state machine.
extension AppContainer {

    // MARK: - Construction

    /// Builds the two Domain engines and the Coordinator that owns them.
    ///
    /// `makeEngine` is a closure rather than a fixed engine because `ProximityEngine` fixes its
    /// device set at construction: when the trusted devices change, the Coordinator has to
    /// rebuild it, and the composition root is the only thing that knows which configuration
    /// and fusion strategy it was built with in the first place.
    func makeCoordinator() -> Coordinator {
        let makeEngine: @Sendable (Set<DeviceID>, CalibrationGate) -> ProximityEngine = { devices, gate in
            ProximityEngine(devices: devices, gate: gate)
        }
        let devices = model.registry.deviceIDs
        let gate = model.calibrationGate
        return Coordinator(
            // The tee, not the raw scanner: see `ObservationTee`.
            scanner: tee,
            screen: screenState,
            session: sessionState,
            power: powerState,
            input: inputActivity,
            lock: lockController,
            wake: wakeController,
            clock: clock,
            engine: makeEngine(devices, gate),
            policy: PolicyEngine(),
            settings: effectiveSettings,
            gate: gate,
            devices: devices,
            makeEngine: makeEngine
        )
    }

    // MARK: - Outbound

    /// Queues one input for the Coordinator.
    ///
    /// Queued rather than awaited so that a SwiftUI action stays synchronous, and queued
    /// through one stream rather than one `Task` each so that inputs keep the order they were
    /// sent in. That order is load-bearing: `.calibrationChanged` before `.devicesChanged`
    /// means the rebuilt engine gets the new gate, and the reverse means it gets the old one.
    ///
    /// A send before `start()` or after `stop()` is dropped, which is correct in both cases:
    /// before `start()` the Coordinator is built from this state anyway, and after `stop()`
    /// there is nothing left to tell.
    func send(_ input: CoordinatorInput) {
        coordinatorInputs?.yield(input)
    }

    /// What the Coordinator should be running on, which is not always what the user has chosen.
    ///
    /// During a calibration run the scan is narrowed to the device being measured and the user
    /// is deliberately walking away from the Mac and back. Those samples are a measurement, not
    /// evidence about presence, so both automatic actions are forced off for the duration —
    /// the fail-closed reading of security.md §2, and cheaper than teaching the engine about a
    /// mode it otherwise has no reason to know exists.
    ///
    /// Derived on every read rather than saved and restored around the run. `PolicySettings` is
    /// a value type, so a saved copy would be a snapshot of the settings as they were when
    /// calibration began; restoring it would silently undo any change the user made in the
    /// Settings window while calibrating. `model.settings` stays the single source of truth and
    /// this is only ever a view of it.
    var effectiveSettings: PolicySettings {
        guard calibration != nil else { return model.settings }
        var muted = model.settings
        muted.autoLock = false
        muted.wakeOnReturn = false
        return muted
    }

    /// Recomputes the gate from the current records and tells the Coordinator.
    func publishGate() {
        model.calibrationGate = currentGate()
        send(.calibrationChanged(model.calibrationGate))
    }

    // MARK: - Inbound

    /// Mirrors one `CoordinatorEvent` into the observable state the UI reads.
    ///
    /// The cases that do nothing here are not oversights. `actionDispatched`,
    /// `actionAcknowledged`, `lifecycle` and `sensorRestart` belong to the diagnostics trail,
    /// which is fed from the same subscription by `DiagnosticsBridge`; putting them on screen
    /// would tell a user about machinery rather than about their Mac.
    func apply(_ event: CoordinatorEvent) {
        switch event {
        case .snapshotUpdated(let snapshot):
            model.snapshotUpdated(snapshot)
            forwardSensorHealthToOnboarding(snapshot.sensor)

        case .transition(let transition):
            model.transitionOccurred(transition)

        case .policyEvaluated(let evaluation):
            model.policyEvaluated(rationale: evaluation.rationale)

        case .actionDispatched, .actionAcknowledged, .lifecycle, .sensorRestart:
            break
        }
    }

    /// Keeps the device-picker step's banner in step with the real sensor.
    ///
    /// Onboarding needs the sensor axis for a reason the main menu does not: its spinner cannot
    /// tell "no advertisements yet" apart from "no advertisements ever, because CoreBluetooth
    /// just reported `.unauthorized`". It gets that from the engine's snapshot rather than from
    /// a second subscription to `scanner.sensorStates`, because that channel has exactly one
    /// consumer and it is the Coordinator.
    ///
    /// Only changes are forwarded: `OnboardingFlow.sensorStatusChanged` restarts discovery when
    /// the sensor recovers from `.unavailable`, and a snapshot that changed for some unrelated
    /// reason must not be able to trigger that.
    private func forwardSensorHealthToOnboarding(_ health: SensorHealth) {
        guard health != lastForwardedSensorHealth else { return }
        lastForwardedSensorHealth = health
        guard let status = Self.sensorStatus(health) else { return }
        onboarding?.sensorStatusChanged(status)
    }

    /// `SensorHealth` back to the adapter-level `SensorStatus` the onboarding flow speaks.
    ///
    /// `nil` for `.initializing`, which has no adapter equivalent: it is the engine saying it
    /// has not heard from the adapter yet, and reporting it as a status would claim knowledge
    /// nobody has.
    static func sensorStatus(_ health: SensorHealth) -> SensorStatus? {
        switch health {
        case .initializing: return nil
        case .healthy: return .available
        case .degraded(let reason): return .degraded(reason)
        case .unavailable(let reason): return .unavailable(reason)
        }
    }
}
