// swift-tools-version: 6.0
//
// `app-smoke` — the headless real-adapter smoke test (docs/specs/architecture.md §3,
// §5.4, system-integration.md §6).
//
// Like `Tools/rssi-record`, and unlike the throwaway probes in `Tools/spikes/`, this is
// a MAINTAINED tool: it is how real-device behaviour of the composition root is checked
// from a terminal and recorded as evidence, so it must keep building. It is a separate
// package rather than a target of the root package so that `swift test` at the root
// never links CoreBluetooth into the test bundle, and so the tool runs without building
// the app bundle.
//
// It depends on the root package by path and boots the *production* `AppContainer` —
// the same adapters, the same Coordinator, the same `OnboardingFlow` the UI drives.
// There is deliberately no second wiring here: a smoke test that assembled its own
// graph would tell you about that graph, not about the app. The only thing it changes
// is where the three JSON stores live (`AppContainer.bootstrap(storageDirectory:)`),
// so a verification run cannot touch the user's real Application Support folder.
//
// The composition root stays the only adapter factory. This tool constructs no adapter.
import PackageDescription

let package = Package(
    name: "app-smoke",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "app-smoke", targets: ["app-smoke"]),
    ],
    dependencies: [
        // `name:` is load-bearing here, not decoration. SwiftPM derives a path
        // dependency's identity from the *last component of the directory path*, not
        // from the `name:` in that dependency's own manifest. Without this, the
        // `package: "Threshold"` references below would resolve only when the checkout
        // directory happens to be called `threshold` — so the tool would build in the
        // main checkout and fail in every git worktree. See Tools/rssi-record.
        .package(name: "Threshold", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "app-smoke",
            dependencies: [
                .product(name: "ThresholdDomain", package: "Threshold"),
                .product(name: "ThresholdSystem", package: "Threshold"),
                .product(name: "ThresholdDiagnostics", package: "Threshold"),
                .product(name: "ThresholdRuntime", package: "Threshold"),
                .product(name: "ThresholdAppKit", package: "Threshold"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
