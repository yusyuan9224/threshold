/// Opaque identity of a trusted device. Wraps whatever string the Bluetooth adapter
/// reports (a CoreBluetooth identifier in production, `device-A` in fixtures).
/// The Domain never interprets its contents.
public struct DeviceID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}
