import Foundation
import ThresholdAppKit
import ThresholdDiagnostics
import ThresholdDomain
import ThresholdRuntime
import ThresholdSystem

/// One headless run against the real composition root.
///
/// Everything below drives `AppContainer` exactly as `ThresholdApp` does — `bootstrap()`,
/// `start()`, `makeOnboardingFlow()`, `stop()` — and only *reads* what the UI would render.
/// It constructs no adapter, opens no second Bluetooth session, and never calls the lock or
/// wake controller: a smoke test that could lock the operator's screen would not get run
/// twice, and locking is not what this verifies (see README).
///
/// `@MainActor` because `AppContainer` is: the container is the lifecycle owner and writes
/// the observable state read here.
@MainActor
enum SmokeRun {

    /// How often `OnboardingFlow` is read during discovery.
    ///
    /// 250 ms is fast enough to catch the ~1 Hz advertising rate of the devices this app
    /// cares about, and slow enough that the poll is not itself the thing being measured.
    static let pollInterval = Duration.milliseconds(250)

    static func run(seconds: Int) async throws {
        let startedAt = Date()
        let directory = try StorageDirectory.resolve(startedAt: startedAt)

        emit("start", [
            ("seconds", JSONLine.int(seconds)),
            ("storage_directory", JSONLine.str(directory.path)),
            ("poll_interval_ms", JSONLine.int(250)),
        ])

        // The production graph, with the stores pointed at a throwaway directory. Nothing
        // else is substituted: this is `CoreBluetoothScanner`, the macOS providers, the real
        // `Coordinator` and the real `DiagnosticsRecorder`.
        let container = AppContainer.bootstrap(bundleIdentifier: nil, storageDirectory: directory)
        container.start()

        emitModel(container, phase: "initial")

        let flow = container.makeOnboardingFlow()
        try await runDiscovery(flow: flow, seconds: seconds, startedAt: startedAt)

        emitModel(container, phase: "after_discovery")
        emitProviders(container)
        await emitCoordinatorEvents(container)

        await container.stop()
        emit("end", [("ok", JSONLine.bool(true))])
    }

    // MARK: - Model

    /// `AppModel` as the menu bar would read it, plus the container state around it.
    private static func emitModel(_ container: AppContainer, phase: String) {
        let model = container.model
        emit("model", [
            ("phase", JSONLine.str(phase)),
            ("protection", JSONLine.str(model.protectionStatus.smokeLabel)),
            ("protection_reason", JSONLine.strOrNull(model.protectionStatus.smokeReason)),
            ("sensor_health", JSONLine.str(model.sensorHealth.label)),
            ("presence", JSONLine.str(model.presence.label)),
            ("calibration_gate", JSONLine.str(model.calibrationGate.smokeLabel)),
            ("registry_count", JSONLine.int(model.registry.devices.count)),
            ("needs_onboarding", JSONLine.bool(container.needsOnboarding)),
            ("coordinator_started", JSONLine.bool(container.coordinator != nil)),
            ("login_item", JSONLine.str(model.loginItemStatus.smokeLabel)),
            // The identity itself is a machine fingerprint and stays out of the transcript;
            // whether one was resolvable is what the calibration gate turns on.
            ("mac_identity_present", JSONLine.bool(container.macIdentity != nil)),
            ("os_major", JSONLine.int(container.osMajorVersion)),
            ("app_version", JSONLine.str(container.appVersion)),
            ("startup_issues", JSONLine.array(model.startupIssues.map(JSONLine.str))),
        ])
    }

    // MARK: - Discovery

    /// Step 1 → 2 of onboarding, run for `seconds` and read on a fixed interval.
    ///
    /// This is the call that creates `CBCentralManager` and so may raise the macOS Bluetooth
    /// permission prompt for whichever process hosts the tool — usually the terminal. Before
    /// it, the container has been started for a while with no prompt at all, which is the
    /// deferral in architecture.md §5.4 being exercised rather than asserted.
    private static func runDiscovery(
        flow: OnboardingFlow,
        seconds: Int,
        startedAt: Date
    ) async throws {
        // The picker hides unnamed identifiers by default (SPIKE-009's noise floor). A smoke
        // run wants the whole room, and the UI has the same switch, so this is still a state
        // the app can be in — it is reported alongside the counts so the numbers are readable.
        flow.showEveryDevice = true

        var lastState = flow.discoveryState
        emitDiscoveryState(lastState, since: startedAt)

        flow.startScanning()

        var sampler = DiscoverySampler()
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            try await Task.sleep(for: pollInterval)
            sampler.sample(flow.rows)
            let state = flow.discoveryState
            if state != lastState {
                lastState = state
                emitDiscoveryState(state, since: startedAt)
            }
        }

        let rows = flow.rows
        emit("notice", [
            ("message", JSONLine.str(
                "identifier_local_use_only values are for LOCAL USE ONLY. Pass one to "
                    + "Tools/rssi-record if you need it; never put one in a fixture, a commit "
                    + "message, an issue, a spec or a chat message."
            )),
        ])
        emit("discovery_summary", [
            ("seconds", JSONLine.int(seconds)),
            ("show_every_device", JSONLine.bool(flow.showEveryDevice)),
            ("total_seen", JSONLine.int(flow.table.totalSeen)),
            ("named_count", JSONLine.int(rows.filter(\.hasName).count)),
            ("final_state", JSONLine.str(lastState.smokeLabel)),
            ("top_by_sightings", JSONLine.array(topRows(rows, sampler: sampler))),
        ])

        // Leaves onboarding the way the window's close button does: discovery stops, whatever
        // was saved stays saved (nothing was), and the container drops the flow.
        flow.cancel()
        emitDiscoveryState(flow.discoveryState, since: startedAt)
    }

    /// The five most-heard identifiers. Most-heard rather than strongest: a device you can
    /// hear forty times is a device, and the loudest row in a block of flats usually is not
    /// the one in your pocket.
    private static func topRows(_ rows: [DiscoveryRow], sampler: DiscoverySampler) -> [String] {
        rows
            .sorted { lhs, rhs in
                lhs.sightings == rhs.sightings ? lhs.id.raw < rhs.id.raw : lhs.sightings > rhs.sightings
            }
            .prefix(5)
            .map { row in
                let median = sampler.median(for: row.id)
                return JSONLine.object([
                    ("name", JSONLine.str(row.advertisedName ?? "unnamed")),
                    ("median_rssi_dbm", median.map { JSONLine.int($0.value) } ?? JSONLine.null),
                    ("rssi_samples", JSONLine.int(median?.samples ?? 0)),
                    ("sightings", JSONLine.int(row.sightings)),
                    ("identifier_local_use_only", JSONLine.str(row.id.raw)),
                ])
            }
    }

    private static func emitDiscoveryState(_ state: OnboardingFlow.DiscoveryState, since startedAt: Date) {
        emit("discovery_state", [
            ("at_ms", JSONLine.int(Int(Date().timeIntervalSince(startedAt) * 1000))),
            ("state", JSONLine.str(state.smokeLabel)),
        ])
    }

    // MARK: - Providers

    /// The four system readings the Coordinator samples when it builds a `PolicySnapshot`
    /// (architecture.md §5.1), read the same way it reads them.
    private static func emitProviders(_ container: AppContainer) {
        let idle = container.inputActivity.current
        emit("providers", [
            ("screen", JSONLine.str(container.screenState.current.smokeLabel)),
            ("session", JSONLine.str(container.sessionState.current.smokeLabel)),
            ("power", JSONLine.str(container.powerState.current.smokeLabel)),
            // `null` is a first-class answer here, not a failure: policy has to treat an
            // unknown idle time as missing supporting evidence (security.md §2 rules 3, 7).
            ("input_idle_seconds", idle.map { JSONLine.number(seconds(of: $0)) } ?? JSONLine.null),
        ])
    }

    private static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: - Coordinator events

    /// Which `CoordinatorEvent` cases the run actually produced, counted per case.
    ///
    /// Read back out of the `DiagnosticsRecorder` rather than off `Coordinator.events`.
    /// That stream is an `AsyncStream` with exactly one iterator — `AppContainer`'s — so a
    /// second `for await` here would take events away from the app under test and leave both
    /// the menu and the audit trail with half of them. `DiagnosticsBridge` maps every event
    /// case onto a distinct category, so reversing that mapping recovers the counts exactly
    /// (see `DiagnosticEvent.Category.coordinatorEventCase`).
    private static func emitCoordinatorEvents(_ container: AppContainer) async {
        let snapshot = await container.recorder.snapshot()

        var counts: [String: Int] = [:]
        var unmapped = 0
        for event in snapshot.events {
            if let name = event.category.coordinatorEventCase {
                counts[name, default: 0] += 1
            } else {
                unmapped += 1
            }
        }

        emit("coordinator_events", [
            ("total_recorded", JSONLine.int(snapshot.totalRecorded)),
            ("buffered", JSONLine.int(snapshot.events.count)),
            ("dropped", JSONLine.int(snapshot.droppedCount)),
            // Categories no `CoordinatorEvent` produces. Non-zero would mean something other
            // than the bridge is writing to the recorder, which is worth knowing about.
            ("non_coordinator_records", JSONLine.int(unmapped)),
            ("counts", JSONLine.object(
                counts.keys.sorted().map { ($0, JSONLine.int(counts[$0] ?? 0)) }
            )),
        ])
    }
}
