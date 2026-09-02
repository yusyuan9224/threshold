# ADR-011 App as SwiftPM Executable; Runtime Library
Status: Accepted (2026-09-02)

## Context
No Xcode.app on the development machine; the CLT SDK contains SwiftUI, AppKit, CoreBluetooth, IOKit, ServiceManagement. MVP 0 evidence: `swift build` links an executable against these frameworks.

## Decision
- The app is a **SwiftPM executable target** `ThresholdApp` (SwiftUI `MenuBarExtra`), bundled into `Threshold.app` by `scripts/make-app-bundle.sh` (Info.plist with `NSBluetoothAlwaysUsageDescription`, `LSUIElement`). An Xcode project is not required for development; it may be added later only for signing/notarization convenience.
- `Coordinator`, `AppContainer`-independent wiring and the diagnostics subscription live in a library target **`ThresholdRuntime`** (→ Domain, Bluetooth, System, Diagnostics) so that L3 Coordinator tests run via `swift test`. `ThresholdApp` keeps only `AppContainer` and UI.

## Consequences
Whole product builds/tests with CLT. `architecture.md` §2 dependency table gains the Runtime row; Coordinator ownership text moves from "App" to "Runtime (owned by App's container)".
