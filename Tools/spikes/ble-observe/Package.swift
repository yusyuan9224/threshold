// swift-tools-version: 6.0
// THROWAWAY spike tool for SPIKE-009 / SPIKE-004. Not a production target.
import PackageDescription
let package = Package(
    name: "ble-observe", platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "ble-observe")],
    swiftLanguageModes: [.v5]
)
