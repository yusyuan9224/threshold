// swift-tools-version: 6.0
import PackageDescription

// Dependency direction is enforced here (see docs/specs/architecture.md §2.3):
//   ThresholdDomain        ← Swift stdlib only
//   ThresholdBluetooth     → Domain
//   ThresholdSystem        → Domain
//   ThresholdDiagnostics   → (leaf; consumed only by Runtime/App)
//   ThresholdRuntime       → Domain, Bluetooth, System, Diagnostics   (Coordinator, wiring)
//   ThresholdAppKit        → Domain, Bluetooth, System, Diagnostics, Runtime
//   ThresholdApp (exec)    → AppKit (+ SwiftUI views and the @main entry point only)
//
// `ThresholdAppKit` is not a new layer: it is the App layer of architecture.md §2.2,
// split out because SwiftPM cannot attach a test target to an executable target.
// Everything in the App layer with behaviour worth asserting — the `AppContainer`
// composition root, the observable UI state, the onboarding and calibration state
// machines — lives in the library, and `ThresholdApp` keeps only what a test could not
// run headlessly anyway. The composition-root rule is unchanged: `AppContainer` is
// still the one place a concrete adapter is constructed.
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
        .target(name: "ThresholdAppKit",
                dependencies: ["ThresholdDomain", "ThresholdBluetooth", "ThresholdSystem",
                               "ThresholdDiagnostics", "ThresholdRuntime"]),
        .executableTarget(name: "ThresholdApp", dependencies: ["ThresholdAppKit"]),

        .testTarget(name: "ThresholdDomainTests", dependencies: ["ThresholdDomain"],
                    resources: [.copy("../Fixtures/BLE")]),
        .testTarget(name: "ThresholdBluetoothTests", dependencies: ["ThresholdBluetooth"]),
        .testTarget(name: "ThresholdSystemTests", dependencies: ["ThresholdSystem"]),
        .testTarget(name: "ThresholdDiagnosticsTests", dependencies: ["ThresholdDiagnostics"]),
        .testTarget(name: "ThresholdRuntimeTests", dependencies: ["ThresholdRuntime"]),
        .testTarget(name: "ThresholdAppKitTests", dependencies: ["ThresholdAppKit"]),
    ],
    swiftLanguageModes: [.v6]
)
