import Foundation
import IOKit

/// Strategy: ask the display wrangler to idle the display now.
///
/// `IOService:/IOResources/IODisplayWrangler` with the `IORequestIdle` property is a public IOKit
/// registry path — no private framework, no entitlement, no elevated privileges (ADR-004).
/// Evidence status (SPIKE-007, 2026-09-03, isolated real-hardware test on a MacBook Pro `Mac17,2` /
/// macOS 26.6.2): `IORegistryEntrySetCFProperty(IORequestIdle)` returns `KERN_SUCCESS`, but the
/// display did **not** sleep within the following 9 s (`screen-state` recorded no `asleep: true`).
/// This strategy therefore does not throw — `MacOSLockController.requestLock()` treats it as
/// accepted and never tries the next strategy — while having no observed effect, so confirmation
/// always times out. It is kept as a fallback (not removed) because a different macOS version or
/// Mac model may honor it; `PMSetDisplaySleepLockStrategy` below is the default primary because it
/// is the one with real-world evidence (`docs/spikes/SPIKE-007-lock-method.md`: 16/16 successful
/// locks, 41–337 ms). When the user has *not* set "require password immediately", either path puts
/// the display to sleep without locking, which is why `MacOSLockController` confirms the outcome
/// against `ScreenStateProviding` rather than trusting the request.
public struct IODisplayWranglerLockStrategy: LockStrategy {
    public let name = "ioRequestIdle"

    public init() {}

    public func requestLock() async throws {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, Self.wranglerPath)
        guard entry != IO_OBJECT_NULL else {
            throw LockStrategyError.unavailable("\(Self.wranglerPath) is not in the IO registry")
        }
        defer { IOObjectRelease(entry) }

        let result = IORegistryEntrySetCFProperty(entry, Self.requestIdleProperty as CFString, kCFBooleanTrue)
        guard result == KERN_SUCCESS else {
            throw LockStrategyError.failed("IORegistryEntrySetCFProperty(\(Self.requestIdleProperty)) returned \(result)")
        }
    }

    private static let wranglerPath = "IOService:/IOResources/IODisplayWrangler"
    private static let requestIdleProperty = "IORequestIdle"
}

/// Default primary strategy: `pmset displaysleepnow`.
///
/// Same effect through a documented, unprivileged command-line tool. `docs/spikes/SPIKE-007-lock-method.md`
/// has 16 real-hardware samples of this exact call, all successful, 41–337 ms from display sleep to
/// `com.apple.screenIsLocked`. Ranked first in `MacOSLockController.defaultStrategies` for that
/// reason — the IOKit strategy above is unproven on some hardware and its raw registry write costs
/// less than spawning a process, but a strategy with no evidence it works should not sit ahead of
/// one with 16/16.
public struct PMSetDisplaySleepLockStrategy: LockStrategy {
    public let name = "pmsetDisplaySleepNow"

    public init() {}

    public func requestLock() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            throw LockStrategyError.unavailable("\(Self.executablePath) is not executable")
        }

        let status = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.executablePath)
            process.arguments = ["displaysleepnow"]
            // The tool prints nothing useful on success and its diagnostics are not ours to log.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // `run()` threw, so the termination handler will never fire and this is the only
                // resume that will happen.
                process.terminationHandler = nil
                continuation.resume(throwing: LockStrategyError.failed("could not launch pmset: \(error)"))
            }
        }

        guard status == 0 else {
            throw LockStrategyError.failed("pmset displaysleepnow exited with status \(status)")
        }
    }

    private static let executablePath = "/usr/bin/pmset"
}
