// swift-tools-version: 6.0
// THROWAWAY spike tool for SPIKE-003. Not a production target.
import PackageDescription
let package = Package(name: "wake-display", platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "wake-display", linkerSettings: [.linkedFramework("IOKit")])],
    swiftLanguageModes: [.v5])
