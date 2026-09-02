import Foundation
import IOKit

/// The machine this app is running on.
///
/// `CalibrationRecord` carries this value so a profile measured on one Mac cannot arm automation on
/// another: RSSI baselines are antenna- and chassis-specific, and a mismatch must land as
/// `NotArmedReason.macMismatch` (security.md §2 rule 4).
public enum MacIdentity {
    /// The `IOPlatformUUID` reported by `IOPlatformExpertDevice`, or `nil` when it is unavailable.
    ///
    /// Public IOKit, no entitlement, no privileges (ADR-004). `nil` rather than a placeholder: a
    /// synthetic identity would compare equal across machines and quietly defeat the check above.
    public static func current() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(platformExpertClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0),
              let identity = property.takeRetainedValue() as? String
        else { return nil }

        let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let platformExpertClass = "IOPlatformExpertDevice"
}
