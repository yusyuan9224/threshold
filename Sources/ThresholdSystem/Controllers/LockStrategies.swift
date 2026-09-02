import Foundation
import IOKit

/// Strategy ①: ask the display wrangler to idle the display now.
///
/// `IOService:/IOResources/IODisplayWrangler` with the `IORequestIdle` property is a public IOKit
/// registry path — no private framework, no entitlement, no elevated privileges (ADR-004).
/// Evidence status: SPIKE-007 has **not** sampled this exact path yet; its two samples (display
/// sleep → session locked in 41 ms and 76 ms, "require password immediately") were taken with
/// `pmset displaysleepnow`, i.e. `PMSetDisplaySleepLockStrategy` below. The two are expected to be
/// equivalent because `pmset` itself sets the same wrangler property, but until SPIKE-007 measures
/// it, this strategy's only safety net is confirmation. When the user has *not* set "require
/// password immediately", either path puts the display to sleep without locking, which is why
/// `MacOSLockController` confirms the outcome against `ScreenStateProviding` rather than trusting
/// the request.
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

/// Strategy ① fallback: `pmset displaysleepnow`.
///
/// Same effect through a documented, unprivileged command-line tool, for machines where the display
/// wrangler is not in the registry. Kept second because spawning a process is slower and coarser
/// than setting the registry property directly.
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
