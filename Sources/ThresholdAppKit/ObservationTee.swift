import ThresholdBluetooth
import ThresholdDomain
import os

/// Splits the scanner's single-consumer observation channel in two, so the monitoring
/// pipeline and a calibration run can both read every sample.
///
/// `AsyncStream` hands each element to exactly one iterator. `Coordinator.observationLoop`
/// iterates `scanner.observations` for as long as the app is running, so a calibration
/// session that iterated the same property would not *duplicate* the channel — it would
/// *race* it, and the two consumers would end up with roughly half the advertisements each.
/// A 20-second near/far step that needs 15 samples would then take twice as long or fail
/// outright, silently and only in the built app.
///
/// This decorator is therefore the one real consumer of the upstream channel. It republishes
/// every observation to the Coordinator's stream and, while a calibration tap is open, to the
/// calibration stream as well. Every other `BLEScanning` member is a straight forward: the tee
/// owns no scanning policy of its own, and the composition root still points at the same
/// concrete adapter it constructed.
///
/// The calibration tap is opened per run rather than kept alive, because a long-lived tap
/// would buffer advertisements from before the run and hand a fresh `CalibrationSession`
/// measurements the user was never asked to stand still for.
///
/// Genuinely `Sendable`: the only mutable state is one continuation behind an
/// `OSAllocatedUnfairLock`, matching the isolation the Bluetooth and System adapters use
/// (architecture.md §4.1).
final class ObservationTee: BLEScanning, Sendable {

    /// Same bound as the upstream monitoring channel: observations are lossy by design, and a
    /// newer RSSI sample supersedes an older one (bluetooth.md §2). Written out rather than
    /// read from `CoreBluetoothScanner` because that constant is internal to the Bluetooth
    /// target; the number matters, the sharing does not.
    static let bufferSize = 64

    private let upstream: any BLEScanning

    /// The Coordinator's copy of the channel.
    let observations: AsyncStream<BLEObservation>
    private let monitoring: AsyncStream<BLEObservation>.Continuation

    /// `nil` unless a calibration run is in progress.
    private let calibration = OSAllocatedUnfairLock(
        initialState: AsyncStream<BLEObservation>.Continuation?.none
    )

    private let pump: Task<Void, Never>

    init(_ upstream: any BLEScanning) {
        self.upstream = upstream
        let (stream, continuation) = AsyncStream<BLEObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferSize)
        )
        self.observations = stream
        self.monitoring = continuation

        // The upstream stream is read out of the property once, here: the pump is the single
        // consumer, and it captures the stream rather than `self` so the tee stays
        // deallocatable and `deinit` can cancel this task.
        let source = upstream.observations
        let calibration = self.calibration
        self.pump = Task {
            for await observation in source {
                continuation.yield(observation)
                calibration.withLock { $0 }?.yield(observation)
            }
            // An upstream end is news the Coordinator has to hear: its restart policy is
            // driven by exactly this (architecture.md §5.4). Swallowing it here would turn a
            // dead adapter into a silent hang.
            continuation.finish()
            calibration.withLock { tap in
                tap?.finish()
                tap = nil
            }
        }
    }

    deinit {
        pump.cancel()
        monitoring.finish()
        calibration.withLock { $0 }?.finish()
    }

    // MARK: - Calibration tap

    /// Opens a fresh stream of observations for a calibration run, closing any previous one.
    ///
    /// Fresh rather than reused so the new run starts empty; see the type's doc comment.
    func openCalibrationTap() -> AsyncStream<BLEObservation> {
        let (stream, continuation) = AsyncStream<BLEObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferSize)
        )
        let previous = calibration.withLock { tap -> AsyncStream<BLEObservation>.Continuation? in
            defer { tap = continuation }
            return tap
        }
        previous?.finish()
        return stream
    }

    func closeCalibrationTap() {
        let tap = calibration.withLock { tap -> AsyncStream<BLEObservation>.Continuation? in
            defer { tap = nil }
            return tap
        }
        tap?.finish()
    }

    // MARK: - BLEScanning (forwarded unchanged)

    var sensorStates: AsyncStream<Timestamped<SensorStatus>> { upstream.sensorStates }
    func discover() -> AsyncStream<DiscoveredDevice> { upstream.discover() }
    func stopDiscovery() { upstream.stopDiscovery() }
    func startScanning(for devices: Set<DeviceID>) { upstream.startScanning(for: devices) }
    func pause() { upstream.pause() }
    func resume() { upstream.resume() }
    func stopScanning() { upstream.stopScanning() }
}
