# ADR-006 Concurrency Model
Status: Accepted (2026-09-02)

## Context
CoreBluetooth 是 delegate + queue 模型；狀態機的資料競爭是最難 debug 的一類 bug。

## Decision
- 單一模型：Swift Concurrency + `AsyncStream`；Swift 6、strict concurrency complete；Combine 零使用；`DispatchQueue` 只出現在 CB 必要參數。
- `Coordinator` 與 `DiagnosticsRecorder` 為 actor；`ProximityEngine`／`PolicyEngine` 為非 Sendable struct，只存在於 Coordinator 內；`AppContainer` 與 UI 為 `@MainActor`；`DiagnosticsRecorder` **不是** MainActor（高頻事件不得經過 UI actor）。
- `CoreBluetoothScanner`：**Option A** — 狀態 confined 到專用 serial queue，public 方法一律 queue-hop，`@unchecked Sendable` 附 invariant、Debug `dispatchPrecondition`、並發測試。Option B（actor 包 delegate）否決：CB 已提供 serial 隔離，再包 actor 只多一次 hop、不多一分 invariant。
- **`Sendable` 是 concurrency contract，不是 decoration**：每個 `@unchecked Sendable` 必須在 spec 列出 invariant、queue-confined property、enforcement 與測試。
- 三通道 scanner stream（observations lossy／sensorStates unbounded／discovery 獨立）。
- Effect lifecycle：`proposed → issued → acknowledged → confirmed | failed → gaveUp`，`stale` 由 `ActionID + EpisodeID` 判定。
- Controller 動作以獨立 Task 執行，outcome 以事件回流 Coordinator；不在 actor 內 await 副作用。
- Sleep／wake：stream 長生命週期不重建；`reset` 由 Coordinator 送入引擎。

## Consequences
狀態機零資料競爭；所有 Domain 型別 Sendable；時間在邊界產生。
