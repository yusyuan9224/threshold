// swift-tools-version: 6.0
// THROWAWAY spike tool for SPIKE-001 / SPIKE-007 / SPIKE-008 / SPIKE-002(partial). Not a production target.
import PackageDescription
let package = Package(name: "screen-state", platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "screen-state", linkerSettings: [.linkedFramework("Carbon")])],
    swiftLanguageModes: [.v5])
