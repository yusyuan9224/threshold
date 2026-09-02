# Architecture Spec

Status: Approved（brainstorming sign-off 2026-09-02）

## 1. 目標

建立一個**可以被測試、可以被推翻錯誤假設、可以隨 macOS 演進替換 system adapter，且不會因為 proximity sensor 出錯就做出危險 security decision** 的系統。

優先順序固定：`Security > Correctness > Reliability > Compatibility > UX > Feature Count`。

## 2. 模組切分：一個 SwiftPM package、多個 target、一個 Xcode app project

### 2.1 為什麼不是多個 package
沒有第二個消費者；多 package 只帶來多份 `Package.resolved` 與跨 package 兩步 commit 的成本。依賴方向由單一 `Package.swift` 的 target dependencies 強制，效果相同。

### 2.2 Targets

| Target | 責任 | May depend on | Must not depend on | Public API | Internal |
|---|---|---|---|---|---|
| `ThresholdDomain` | 全部純邏輯：observation 型別、訊號管線、presence、calibration、狀態機、policy、action ledger | **Swift stdlib**（`Codable`、`Duration`）。Foundation 非教條禁止，但目前不需要；**禁止** macOS framework 與任何副作用 | Foundation（目前）、CoreBluetooth、其他 target | 各 area 的 value type；`ProximityEngine.handle(_:)`；`PolicyEngine.evaluate(_:trigger:)`／`acknowledge(...)`；`CalibrationSession`；`CalibrationValidator`；`DriftDetector` | 濾波器係數、轉換表實作、ledger 內部 |
| `ThresholdBluetooth` | CoreBluetooth → 三通道 AsyncStream；掃描生命週期；`DeviceRegistry` | Domain（輸出型別就是 `BLEObservation`／`SensorStatus`）、Foundation、CoreBluetooth | System、Diagnostics、App | `BLEScanning`、`CoreBluetoothScanner`、`FakeScanner`、`DeviceRegistry` | delegate → stream 橋接、queue confinement、重掃邏輯 |
| `ThresholdSystem` | 所有 macOS 接觸面：providers（Screen／Session／Power／InputActivity）與 controllers（Lock／Wake／LoginItem）、persistence stores | Domain（產出 `ScreenState` 等、接受 `PolicyAction`）、Foundation、AppKit、IOKit、CoreGraphics、ServiceManagement | Bluetooth、Diagnostics、App | 每個能力一組 `protocol + macOS 實作 + Fake` | 未文件化訊號的讀取細節只在這裡 |
| `ThresholdDiagnostics` | `DiagnosticEvent` schema、`DiagnosticsRecorder` actor（環形緩衝、隱私過濾、匯出） | Foundation、os.log | 所有其他 target | `DiagnosticEvent`、`DiagnosticsRecorder`、`DiagnosticsSnapshot` | 去識別化規則 |
| `Threshold`（App，Xcode target） | `AppContainer`（composition root）、`Coordinator` actor、SwiftUI UI、`DiagnosticsRecorder` 的訂閱與轉換 | 全部 | — | — | — |

`ThresholdSecurity` 是 **reserved target**：MVP 0–5 沒有 consumer，MVP 6 且 SPIKE-001／002 GO 才建立。介面見 `security.md`。

### 2.3 依賴圖

```text
ThresholdDomain          （stdlib only）
    ▲            ▲
ThresholdBluetooth   ThresholdSystem        ThresholdDiagnostics（獨立葉節點）
    ▲            ▲                               ▲
    └── Threshold (App) ─────────────────────────┘
```

Bluetooth 與 System 互不依賴；只透過 Domain value type 對話，中介是 App 的 Coordinator。**Domain 不知道 Diagnostics 存在**：Domain 以回傳值輸出 transition／decision／rationale，App 層的 `DiagnosticsRecorder` 訂閱 Coordinator 事件後轉成 `DiagnosticEvent`。

### 2.4 Domain 內部 bounded areas

```text
Sources/ThresholdDomain/
├── Observation/    DeviceID, MonotonicInstant, BLEObservation, SensorStatus, ObservationValidator
├── Signal/         SignalWindow, MedianFilter, EMAFilter, SignalEstimate
├── Presence/       PresenceScore, PresenceScorer, DeviceTrack, DeviceObservationState, PresenceFusion
├── Calibration/    CalibrationSession, CalibrationProfile, CalibrationRecord, CalibrationValidator, CalibrationGate, CalibrationPolicy, DriftDetector
├── StateMachine/   PresenceState, SensorHealth, ProximityEngine, ProximitySnapshot, ProximityTransition, EngineInput, EngineConfiguration
└── Policy/         PolicySnapshot, RequiredPreconditions, SupportingEvidence, PolicySettings, PolicyEngine, PolicyAction, ActionLedger, PolicyRationale
```

目的：避免 Domain 成為所有純 Swift code 的 catch-all。新增檔案必須落在其中一個 area；找不到 area 就是設計訊號。

## 3. Composition root：`AppContainer`

`@MainActor final class AppContainer`，App target 內**唯一**有權建立 concrete adapter 的地方。負責：

- 建立 production adapters：`CoreBluetoothScanner`、`MacOSScreenStateProvider`、`MacOSSessionStateProvider`、`MacOSPowerStateProvider`、`MacOSInputActivityProvider`、`MacOSLockController`、`MacOSWakeController`、`SMAppServiceLoginItemController`、stores、`ContinuousMonotonicClock`
- 從 stores 載入 `DeviceRegistry`、`CalibrationRecord`、`PolicySettings`，計算初始 `CalibrationGate`
- 建立 `ProximityEngine`／`PolicyEngine` 並交給 `Coordinator`
- 擁有所有長生命週期 Task 的 handle；App 結束時 `coordinator.stop()` → `scanner.stopScanning()`
- 建立 `DiagnosticsRecorder` actor 並啟動訂閱 Task
- 未來的 Pro 擴充點也在此（ADR-005；目前無 protocol）

Domain／Bluetooth／System 內部**不得** new 彼此的 concrete 實作。測試用 `TestContainer` 全部換 Fake。

不使用 DI framework：五到十個物件的手動組裝不需要框架。

## 4. Concurrency Model

單一模型：**Swift Concurrency + AsyncStream**。Combine 零使用；`DispatchQueue` 只出現在 CoreBluetooth 的必要參數。Swift 6 語言模式、strict concurrency = complete。

### 4.1 隔離分配

| 物件 | 隔離 | 理由 |
|---|---|---|
| `CoreBluetoothScanner` | `final class`，狀態 confined 到專用 serial `scanQueue`（傳給 `CBCentralManager(delegate:queue:)`）；`@unchecked Sendable` 附 invariant（見 `bluetooth.md` §5） | CoreBluetooth 已提供 serial queue 隔離；再包 actor 只多一次 hop、不多一分 invariant（ADR-006） |
| `ProximityEngine`、`PolicyEngine` | 非 Sendable struct，只存在於 `Coordinator` actor 內，永不逃逸 | actor 序列化 = 狀態機零資料競爭 |
| `Coordinator` | `actor` | 見 §5 |
| System providers | `final class: Sendable`；stored property 只有 `let continuation` 與 `OSAllocatedUnfairLock<State>` | 全部 stored property 皆 Sendable，不需 `@unchecked` |
| Controllers | `final class: Sendable`，無可變狀態 | 只有 `let` 依賴 |
| `MonotonicClock`（production） | `struct` 包 `ContinuousClock` | value type |
| `AppContainer`、UI view models（`@Observable`） | `@MainActor` | UI 與生命週期擁有者 |
| `DiagnosticsRecorder` | `actor` | 高頻事件不得經過 MainActor |
| 所有 Domain value type、stream payload | `Sendable` | 跨隔離邊界的唯一貨幣 |

### 4.2 時間

```swift
protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
    func sleep(until: MonotonicInstant) async throws
}
```
時間在**邊界**產生（scanner／providers 在 yield 時打上 `clock.now()`）；Domain 只消費輸入內的 `MonotonicInstant`，從不呼叫任何 clock。Wall-clock 型別不存在於 Domain。

### 4.3 Configuration
`PolicySettings`、`EngineConfiguration`、`CalibrationPolicy` 皆為 value type。UI 修改 → store 持久化 → 以 `.settingsChanged(PolicySettings)` 事件送進 Coordinator。沒有共享可變設定物件。

## 5. Coordinator（actor）

### 5.1 Owns
- 一個 `runTask`，內以 `withTaskGroup` 為每個輸入 stream 開 child task；child 只做 `for await x in stream { await self.handle(.x) }`
- `ProximityEngine`、`PolicyEngine` 實例；最新的 `ScreenState`／`SessionState`／`PowerState`／`PolicySettings`／`CalibrationGate` 快取
- `deadlineTask`：依 `min(engine.nextDeadline, policy.nextDeadline)` 以 `clock.sleep(until:)` 排程一次 `.tick`
- 組 `PolicySnapshot`（快取 + 當下輪詢 `inputIdle` + `clock.now()`）並呼叫 `PolicyEngine.evaluate`
- 派發 `PolicyAction` 給 controller（以獨立 Task 執行，**不在 actor 內 await 完成**），完成後 `self.handle(.actionOutcome(actionID, episodeID, outcome))`
- 對外 `AsyncStream<CoordinatorEvent>`：`snapshotUpdated`、`transition`、`policyEvaluated`、`actionDispatched`、`actionAcknowledged`、`lifecycle`

### 5.2 Does not own
- RSSI 運算、presence 判斷、policy 規則（Domain）
- `CBCentralManager`／delegate 細節（Bluetooth）
- CGEvent／IOKit／通知名稱（System）
- diagnostics 格式、wall-clock、匯出（`DiagnosticsRecorder`）
- UI state、選單文字、onboarding（App）
- 持久化（stores 由 `AppContainer` 擁有；Coordinator 只收 `.settingsChanged`／`.calibrationChanged`／`.devicesChanged` 事件）

大小警戒線：超過 400 行即為責任外溢。

### 5.3 統一入口
```swift
actor Coordinator {
    func handle(_ input: CoordinatorInput) async
    // 1. 更新快取，或送進 ProximityEngine（回傳 [ProximityTransition]）
    // 2. 有 transition／系統狀態變化／tick／settings 變化 → 建 snapshot → PolicyEngine.evaluate
    // 3. 有 action → dispatch（Task），outcome 以事件回流
    // 4. 重排 deadline；emit CoordinatorEvent
}
```

### 5.4 生命週期
- **啟動**：`CBCentralManager` 延後建立到「已有註冊裝置」或「使用者進入裝置設定」，避免啟動即跳權限框。
- **`.systemWillSleep`**：`power = .systemAsleep`；取消 `deadlineTask`；`scanner.pause()`。
- **`.systemDidWake`**：`power = .awake`；`engine.handle(.reset(.systemWake))`；`scanner.resume()`；重評 policy（預期無動作）。
- **`.screensDidSleep`／`.screensDidWake`**：只更新 `power`，不 reset。
- **Stream**：scanner／providers 的 stream 長生命週期，不因 sleep／wake 重建；scanner 內部處理重掃並以 sensor 通道回報 `.degraded(.scanInterrupted)` → `.healthy`。stream 意外結束 → 視為 `.unavailable(.scannerFailed)`，`restart()` 最多 3 次（間隔 2 s）。
- **停止**：`stop()` 取消 `runTask` 與 `deadlineTask`；執行中的 controller Task 不強制取消（鎖定應完成），其 outcome 在 stop 後回來則忽略。
- **受信任裝置變更**：`AppContainer` 更新 registry → `scanner.startScanning(for:)` → `.reset(.devicesChanged)` + `.calibrationChanged(gate)`。

## 6. Effect lifecycle

```text
proposed → issued → acknowledged → confirmed
                 ↘ failed → (retry ≤ maxAttempts) → gaveUp
任何階段：outcome 的 actionID 不存在或 episodeID ≠ ledger entry → stale（只記 diagnostics，不動 ledger，不重派）
```
- `proposed`：PolicyEngine 輸出、尚未 dispatch——唯一可取消階段（MVP 中瞬時；Assisted Unlock 在此做最後 guard 重檢）。
- `issued`：已交給 controller——effect 已 committed；presence 回復不撤回。
- `ActionID` + `EpisodeID` 隨 action 流過整條 effect pipeline。

## 7. 明確不做（YAGNI）
DI container、`Automation` target（MVP 只有 `EventScriptRunner`，屬 System，且不在 MVP 0–4 範圍）、`ProFeatureProvider` protocol（ADR-005：等第一個 consumer）、IOBluetooth（ADR-004）、多 package。
