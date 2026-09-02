import ThresholdBluetooth
import ThresholdDomain
import ThresholdSystem

/// The input side of the Coordinator: one child task per boundary stream (architecture.md §5.1).
///
/// Each loop is actor-isolated, so an element is turned into a `handle(_:)` call without ever
/// leaving the actor. The loops suspend between elements, which is what lets five of them coexist
/// on one actor without any of them blocking the others.
extension Coordinator {

    func runLoops() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.observationLoop() }
            group.addTask { [weak self] in await self?.sensorLoop() }
            group.addTask { [weak self] in await self?.screenLoop() }
            group.addTask { [weak self] in await self?.sessionLoop() }
            group.addTask { [weak self] in await self?.powerLoop() }
        }
    }

    /// Observations, plus the restart policy for a scanner that dies.
    ///
    /// A finished observation stream is never expected — the streams are long-lived across sleep
    /// and wake, and the scanner reports its own interruptions on the sensor channel instead. So an
    /// end means the adapter is gone: the sensor axis is told, which fails every precondition
    /// closed, and scanning is restarted at most `maxScannerRestarts` times, `scannerRestartDelay`
    /// apart (§5.4).
    ///
    /// Only this channel triggers restarts. `sensorStates` ends at the same moment when the whole
    /// adapter shuts down, and reacting to both would double every attempt.
    ///
    /// 實作註記 2026-09-03: `CoreBluetoothScanner.observations` only finishes its continuation in
    /// `deinit` (see `CoreBluetoothScanner.swift`), and the Coordinator holds its scanner strongly
    /// for as long as the Coordinator itself is alive. So in a production `Coordinator`, this loop
    /// observing a finished stream means the scanner instance is already gone — not merely
    /// misbehaving — and the restart attempts below cannot actually revive it; `scanner.startScanning`
    /// is called on the same (now-deallocated-or-going-to-be) instance. The loop still runs its
    /// bounded restart sequence rather than special-casing this, which is what makes the outcome a
    /// clean, observable, fail-closed shutdown (`.unavailable(.scannerFailed)` after
    /// `maxScannerRestarts` attempts) instead of a silent hang — the failure mode this code is
    /// actually defending against is a *test* `BLEScanning` fake ending its stream, or a future
    /// adapter with different lifetime semantics, not a live `CoreBluetoothScanner` restarting
    /// itself mid-flight.
    func observationLoop() async {
        var attempt = 0
        while !Task.isCancelled, !isStopped {
            for await observation in scanner.observations {
                handle(.observation(observation))
            }
            guard !Task.isCancelled, !isStopped else { return }

            handle(.sensor(.unavailable(.scannerFailed), at: clock.now()))
            guard attempt < Self.maxScannerRestarts else { return }
            attempt += 1

            do {
                try await clock.sleep(for: Self.scannerRestartDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, !isStopped else { return }

            scanner.startScanning(for: devices)
            emit(.sensorRestart(attempt: attempt))
        }
    }

    func sensorLoop() async {
        for await status in scanner.sensorStates {
            handle(.sensor(status.value, at: status.at))
        }
    }

    func screenLoop() async {
        for await state in screenProvider.changes {
            handle(.screen(state.value, at: state.at))
        }
    }

    func sessionLoop() async {
        for await state in sessionProvider.changes {
            handle(.session(state.value, at: state.at))
        }
    }

    func powerLoop() async {
        for await state in powerProvider.changes {
            handle(.power(state.value, at: state.at))
        }
    }
}
