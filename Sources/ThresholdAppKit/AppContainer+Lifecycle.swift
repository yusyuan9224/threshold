import ThresholdBluetooth
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem

/// Start-up, shutdown, and the long-lived tasks in between (architecture.md §3).
extension AppContainer {

    // MARK: - Start

    /// Loads persisted state, builds the Coordinator, arms scanning if there is a device to
    /// scan for, and starts the long-lived tasks.
    ///
    /// Store failures are collected into `AppModel.startupIssues` instead of throwing. A
    /// `settings.json` this build cannot read must not stop the app from launching, but it
    /// must also never be silently replaced with defaults — the user is told, and the file is
    /// left alone.
    ///
    /// Synchronous on purpose, even though `Coordinator.start()` is not: everything the first
    /// frame of UI reads — the registry, the gate, the settings, the startup issues, the set
    /// of devices being scanned for — is settled before this returns. Only the actor work is
    /// deferred, into `coordinatorTask`.
    public func start() {
        var issues: [String] = []
        if let deferredStartupIssue {
            issues.append(deferredStartupIssue)
            self.deferredStartupIssue = nil
        }

        var registry = DeviceRegistry()
        do {
            for record in try deviceStore.load() {
                registry = registry.adding(id: record.device, name: record.name)
            }
        } catch {
            issues.append(StoreErrorText.describe(error))
        }
        model.registry = registry

        do {
            calibrationRecords = try calibrationStore.load()
        } catch {
            issues.append(StoreErrorText.describe(error))
        }

        do {
            if let stored = try settingsStore.load() { model.settings = stored }
        } catch {
            issues.append(StoreErrorText.describe(error))
        }

        model.startupIssues = issues
        model.calibrationGate = currentGate()
        refreshLoginItemStatus()

        needsOnboarding = registry.isEmpty
        // Synchronously, so the very first thing a test or a UI reads about the scanner is
        // already true. The Coordinator asks for the same set again when it starts; both calls
        // are the same intent, and `startScanning(for:)` is idempotent.
        armScanning(notifyCoordinator: false)

        startCoordinator()
        diagnosticsTask = Task { [weak self] in await self?.runDiagnosticsPoll() }
    }

    /// Builds the Coordinator with the loaded state and opens its three channels.
    ///
    /// The Coordinator is started even with an empty registry. That does not raise the
    /// Bluetooth permission prompt: `Coordinator.start()` skips `startScanning` for an empty
    /// device set, and `CoreBluetoothScanner` creates its `CBCentralManager` only when it is
    /// asked to scan for a non-empty set or to discover (architecture.md §5.4, verified in
    /// `CoreBluetoothScanner.performStartScanning`). Starting it anyway is what gives
    /// onboarding a live sensor axis: `scanner.sensorStates` has exactly one consumer — the
    /// Coordinator — so a container that waited for a trusted device before starting would
    /// leave the device picker unable to tell "no advertisements yet" from "Bluetooth is off".
    private func startCoordinator() {
        let coordinator = makeCoordinator()
        self.coordinator = coordinator

        let (inputs, continuation) = AsyncStream<CoordinatorInput>.makeStream(
            bufferingPolicy: .unbounded
        )
        coordinatorInputs = continuation

        let events = coordinator.events
        eventsTask = Task { [weak self] in await self?.runEventChannel(events) }
        coordinatorTask = Task {
            await coordinator.start()
            for await input in inputs {
                await coordinator.handle(input)
            }
        }
    }

    // MARK: - Stop

    /// Stops the Coordinator, then the scanner, then everything else.
    ///
    /// That order is required (architecture.md §3): the Coordinator restarts scanning by
    /// itself — on a device-set change and on an unexpected stream end — so telling the
    /// scanner to stop first would leave a live actor free to arm it again afterwards.
    ///
    /// `async` for the same reason. A fire-and-forget `Task` would return before the actor had
    /// stopped and make that ordering a race, which is exactly what must not be left to chance
    /// on the path that runs when the app is quitting.
    ///
    /// Controller work already in flight is not cancelled: a lock that has been issued should
    /// finish, and its outcome is ignored once the Coordinator has stopped (§5.4).
    ///
    /// Idempotent: quitting from the menu and `applicationWillTerminate` both land here.
    public func stop() async {
        coordinatorInputs?.finish()
        coordinatorInputs = nil

        await coordinator?.stop()
        coordinator = nil

        coordinatorTask?.cancel(); coordinatorTask = nil
        eventsTask?.cancel(); eventsTask = nil
        diagnosticsTask?.cancel(); diagnosticsTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        calibrationTask?.cancel(); calibrationTask = nil
        tee.closeCalibrationTap()

        scanner.stopDiscovery()
        scanner.stopScanning()
    }

    // MARK: - Channels

    /// The single subscription to `Coordinator.events`, fanned out to the two things that
    /// need it.
    ///
    /// `AsyncStream` delivers each element to one iterator only, so this cannot be two tasks:
    /// a `DiagnosticsBridge` iterating `events` separately would take events away from the
    /// model and leave the menu showing a stale belief — and the whole point of the unbounded
    /// event buffer is that the audit trail loses nothing.
    ///
    /// Running on the main actor is affordable because the flood-prone case is already
    /// coalesced at the source: `snapshotUpdated` is published only when the engine's belief
    /// actually changes, not once per advertisement (`Coordinator.emitSnapshotUpdate`).
    func runEventChannel(_ events: AsyncStream<CoordinatorEvent>) async {
        let bridge = DiagnosticsBridge(recorder: recorder, clock: clock)
        for await event in events {
            apply(event)
            await bridge.record(event)
        }
    }

    /// Polls the recorder at 1 Hz (ADR-007), so high-frequency events never touch the main actor.
    func runDiagnosticsPoll() async {
        while !Task.isCancelled {
            model.diagnostics = await recorder.snapshot()
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    // MARK: - Scanning

    /// Scans for exactly the registered devices, or not at all when there are none.
    ///
    /// `notifyCoordinator` is false only during `start()`, where the Coordinator is about to
    /// be constructed around this very device set and a `.devicesChanged` would ask it to
    /// rebuild engines it has not built yet.
    func armScanning(notifyCoordinator: Bool = true) {
        let devices = model.registry.deviceIDs
        scanner.startScanning(for: devices)
        if notifyCoordinator { send(.devicesChanged(devices)) }
    }
}
