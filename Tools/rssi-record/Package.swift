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
        // `name:` is load-bearing here, not decoration. SwiftPM derives a path
        // dependency's identity from the *last component of the directory path*,
        // not from the `name:` in that dependency's own manifest. Without this,
        // the `package: "Threshold"` references below resolve only when the
        // checkout directory happens to be called `threshold` — so the tool built
        // in the main checkout and failed in every git worktree, and would have
        // failed in any clone into a differently named directory.
        .package(name: "Threshold", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "rssi-record",
            dependencies: [
                .product(name: "ThresholdDomain", package: "Threshold"),
                .product(name: "ThresholdBluetooth", package: "Threshold"),
            ]
        ),
        // Argument parsing only — no CoreBluetooth is exercised here, so this runs in CI on a
        // machine with no radio. Testing the executable target directly works because the entry
        // point is `@main` in RSSIRecord.swift rather than top-level code in a `main.swift`.
        .testTarget(
            name: "rssi-recordTests",
            dependencies: ["rssi-record"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
