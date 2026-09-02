import Dispatch
import Foundation
import ThresholdDomain

/// Progress, sensor transitions and errors go to **stderr**; only the discovery
/// table goes to stdout. That split is what lets `rssi-record discover` be read by a
/// human while its stderr is left attached to the terminal, and it keeps the tool
/// from ever writing an identifier into a redirected file by accident.
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Tracks the sensor channel's health alongside the recording.
///
/// Kept apart from `Recording` because it answers a different question: `Recording`
/// is what goes in the fixture, this is whether the run is worth keeping at all.
actor SensorWatch {
    private(set) var sawAvailable = false
    private(set) var last: SensorStatus?

    func note(_ status: SensorStatus) {
        last = status
        if status == .available { sawAvailable = true }
    }

    /// The message for a run that never got a usable radio. `nil` when the run is fine.
    func unusableReason() -> String? {
        guard !sawAvailable else { return nil }
        guard let last else {
            return """
                Bluetooth never reported a state. CoreBluetooth stayed in `.unknown`, \
                which usually means the permission prompt was never answered. Grant \
                Bluetooth access to your terminal in System Settings › Privacy & \
                Security › Bluetooth and run again.
                """
        }
        return "Bluetooth never became available. Last SensorStatus: \(last.fixtureName)"
    }
}

/// SIGINT as an `AsyncStream`, so a long field run can be stopped early and still
/// write its fixture instead of losing thirty minutes of walking about.
///
/// The returned source must be kept alive for as long as the stream is consumed —
/// a `DispatchSourceSignal` stops delivering once it is deallocated.
func interruptSignal() -> (stream: AsyncStream<Void>, source: DispatchSourceSignal) {
    // The default disposition would kill the process before the handler ran.
    signal(SIGINT, SIG_IGN)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { continuation.yield(()) }
    source.resume()
    return (stream, source)
}

/// Whole seconds, for stderr lines that a human is reading in real time.
func seconds(fromMs milliseconds: Int64) -> Int64 { milliseconds / 1000 }
