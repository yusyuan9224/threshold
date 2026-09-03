# ADR-011 App as SwiftPM Executable; Runtime Library
Status: Accepted (2026-09-02)

## Context
No Xcode.app on the development machine; the CLT SDK contains SwiftUI, AppKit, CoreBluetooth, IOKit, ServiceManagement. MVP 0 evidence: `swift build` links an executable against these frameworks.

## Decision
- The app is a **SwiftPM executable target** `ThresholdApp` (SwiftUI `MenuBarExtra`), bundled into `Threshold.app` by `scripts/make-app-bundle.sh` (Info.plist with `NSBluetoothAlwaysUsageDescription`, `LSUIElement`). An Xcode project is not required for development; it may be added later only for signing/notarization convenience.
- `Coordinator`, `AppContainer`-independent wiring and the diagnostics subscription live in a library target **`ThresholdRuntime`** (→ Domain, Bluetooth, System, Diagnostics) so that L3 Coordinator tests run via `swift test`. `ThresholdApp` keeps only `AppContainer` and UI.

## Consequences
Whole product builds/tests with CLT. `architecture.md` §2 dependency table gains the Runtime row; Coordinator ownership text moves from "App" to "Runtime (owned by App's container)".

## Amendment 2026-09-02
Xcode 26.6 (17F113) is now installed on the development machine (macOS 26.6.2, build 25G83); the original Context ("No Xcode.app on the development machine") no longer holds.

**The decision stands.** The app remains a SwiftPM executable target bundled by `scripts/make-app-bundle.sh`; no Xcode project is added. The availability of Xcode removes the constraint that forced this shape, not the reasons to keep it: one build path for developers and CI, no `.xcodeproj` to keep in sync with `Package.swift`, and no per-machine IDE state in version control. Xcode may still be used for signing/notarization convenience (`docs/release.md` §4), which needs no project file either — `codesign` and `notarytool` operate on the assembled bundle.

CI runs the bundle script as a build step (`.github/workflows/ci.yml`, `scripts/make-app-bundle.sh debug`), so the bundling path is covered by every pull request rather than only at release time.

The App layer is now split across two targets. **`ThresholdAppKit`** is a library holding the composition root (`AppContainer`), the observable UI state (`AppModel`), and the onboarding and calibration state machines; `ThresholdApp` keeps only the SwiftUI views and the `@main` entry point. The reason is the same one that produced `ThresholdRuntime`: SwiftPM cannot attach a test target to an executable target, so anything with behaviour worth asserting has to live in a library to be reachable from `swift test`. This is not a new architectural layer — `AppContainer` is still the single place a concrete adapter is constructed (architecture.md §2.2).
