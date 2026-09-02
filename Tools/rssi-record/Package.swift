// swift-tools-version: 6.0
//
// `rssi-record` — the MVP 1B field recorder (docs/specs/testing.md §3,
// docs/spikes/SPIKE-009 §A/§B/§C).
//
// Unlike the throwaway probes in `Tools/spikes/`, this is a MAINTAINED tool: the
// fixtures it produces are the replay corpus for the engine, so it must keep
// building. It is a separate package (not a target of the root package) so that
// `swift test` at the root never links CoreBluetooth into the test bundle, and so
// the tool can be run without building the app.
//
// It depends on the root package by path and uses the *production*
// `ThresholdBluetooth.CoreBluetoothScanner`. There is deliberately no second
// CoreBluetooth code path here: SPIKE-009/SPIKE-004 evidence is only worth
// anything if it comes through the scanner the app actually ships.
import PackageDescription

let package = Package(
    name: "rssi-record",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rssi-record", targets: ["rssi-record"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "rssi-record",
            dependencies: [
                .product(name: "ThresholdDomain", package: "Threshold"),
                .product(name: "ThresholdBluetooth", package: "Threshold"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
