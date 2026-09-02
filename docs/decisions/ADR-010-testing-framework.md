# ADR-010 Testing Framework
Status: Accepted (2026-09-02)

## Context
本機只有 Command Line Tools（Swift 6.2），無 Xcode.app，CLT 內無 `Testing.swiftmodule`。MVP 0 的 exit criteria 是 fresh clone → `swift build` → `swift test`。

## Decision
- MVP 0 起使用 **XCTest**；核心 package 在 CLT 下可建置與測試。
- Xcode 到位後重評 Swift Testing（參數化測試對 fixture replay 有價值）；若遷移，一次遷移整個 package，不混用。
- App target（SwiftUI）在 MVP 0 只建骨架，標記「需 Xcode 驗證」；CI 於有 Xcode 的 runner 上執行 `xcodebuild`。

## Consequences
本機可立即進入 TDD；App 層驗證延後到 Xcode 安裝。
