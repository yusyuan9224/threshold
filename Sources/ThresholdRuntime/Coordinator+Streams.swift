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
