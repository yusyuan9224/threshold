// swift-tools-version: 6.0
import PackageDescription

// Dependency direction is enforced here (see docs/specs/architecture.md §2.3):
//   ThresholdDomain        ← Swift stdlib only
//   ThresholdBluetooth     → Domain
//   ThresholdSystem        → Domain
//   ThresholdDiagnostics   → (leaf; consumed only by Runtime/App)
//   ThresholdRuntime       → Domain, Bluetooth, System, Diagnostics   (Coordinator, wiring)
//   ThresholdApp (exec)    → Runtime (+ SwiftUI)
let package = Package(
    name: "Threshold",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ThresholdApp", targets: ["ThresholdApp"]),
        // Library products exist so maintained tools under Tools/ can depend on this
        // package by path and drive the *production* adapters rather than a parallel
        // copy of them (Tools/rssi-record uses ThresholdBluetooth.CoreBluetoothScanner,
        // so its field evidence comes through the code the app ships).
        // Only the two targets a tool legitimately needs are exported; Runtime and
        // System stay internal so nothing outside the package can bypass the
        // composition root.
        .library(name: "ThresholdDomain", targets: ["ThresholdDomain"]),
        .library(name: "ThresholdBluetooth", targets: ["ThresholdBluetooth"]),
    ],
    targets: [
        .target(name: "ThresholdDomain"),
        .target(name: "ThresholdBluetooth", dependencies: ["ThresholdDomain"]),
        .target(name: "ThresholdSystem", dependencies: ["ThresholdDomain"]),
        .target(name: "ThresholdDiagnostics"),
        .target(name: "ThresholdRuntime",
                dependencies: ["ThresholdDomain", "ThresholdBluetooth", "ThresholdSystem", "ThresholdDiagnostics"]),
        .executableTarget(name: "ThresholdApp", dependencies: ["ThresholdRuntime"]),

        .testTarget(name: "ThresholdDomainTests", dependencies: ["ThresholdDomain"],
                    resources: [.copy("../Fixtures/BLE")]),
        .testTarget(name: "ThresholdBluetoothTests", dependencies: ["ThresholdBluetooth"]),
        .testTarget(name: "ThresholdSystemTests", dependencies: ["ThresholdSystem"]),
        .testTarget(name: "ThresholdDiagnosticsTests", dependencies: ["ThresholdDiagnostics"]),
        .testTarget(name: "ThresholdRuntimeTests", dependencies: ["ThresholdRuntime"]),
    ],
    swiftLanguageModes: [.v6]
)
