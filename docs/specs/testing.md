# Testing Spec

Status: Approved（2026-09-02）

## 0. Definition of Done（每個 task）
Implementation + Tests + Documentation + Diagnostics（若適用）+ No known security regression。**「It compiles」不算 Done。**

## 1. 四層

| 層 | 對象 | 工具 | 決定性來源 |
|---|---|---|---|
| L1 Domain unit | Signal／Presence／StateMachine／Policy／Calibration 每條規則 | XCTest（CLT 可跑；ADR-010） | 純函式 + `MonotonicInstant` 輸入 |
| L2 Fixture replay | `ProximityEngine` 對錄製序列的完整輸出 | XCTest + `Tests/Fixtures/BLE/*.jsonl` | 同一輸入永遠同一輸出 |
| L3 Coordinator integration | 三軸 + Policy + ledger + deadline 協作 | `FakeScanner`、`Fake*Provider`、`FakeClock`（手動推進）、`SpyLockController`、`SpyWakeController` | actor 序列化 + FakeClock |
| L4 System adapter | macOS 實作 | Spike 檢查清單 + 最少量 XCTest（映射、fail-closed 回 `.unknown`） | 實機；不自動化 |

## 2. 必備回歸測試（缺一不可）

| ID | 測試 | 層 |
|---|---|---|
| T-01 | RSSI 序列 `-62 -61 -20 -63 -64`：outlier 不造成 present transition | L1 |
| T-02 | `unknown → present`、`present → departing → away`、`away → present` 正反向 | L1 |
| T-03 | Scanner failure（`sensor(.unavailable)`）不得 → away、不得 lock | L1+L3 |
| T-04 | Calibration near／far overlap → `.overlap` failure，不產生 profile | L1 |
| T-05 | `settings.autoLock == false` → 任何 away 都不 lock | L1 |
| T-06 | `screen == .unknown` → `.none(.preconditionIndeterminate(.screen))` | L1 |
| T-07 | Race：lock 已 issued，presence 回復 → 新 episode；舊 outcome 回來 → `.stale`，ledger 不變 | L1+L3 |
| T-08 | 喚醒後（`reset(.systemWake)`）3 s 內任何輸入都不可能 lock | L3 |
| T-09 | 連續五次 snapshot（screen 尚未更新）只 dispatch 一次 lock | L1 |
| T-10 | `evidenceExpired + inputIdle == nil` → `.none(.insufficientEvidence)` | L1 |
| T-11 | `measuredFar + inputIdle == nil` → lock 允許 | L1 |
| T-12 | `sensor != healthy` 且 presence == away 且 screen unlocked → 不 lock | L1 |
| T-13 | present 時突然 silent（無先弱）→ `unknown(.evidenceExpired)`，evidence == `.none`，**不是** away | L1 |
| T-14 | departing 後 silent 且前 k 筆 < exit → away，evidence == `.departureThenSilent`；`lockOnDepartureThenSilent == false` 時不 lock | L1 |
| T-15 | 隨機 `EngineInput` 序列 100,000 次：不出現非法轉換（屬性測試） | L1 |
| T-16 | Wake 只在 `now − presenceSince ≤ wakeWindow` 內發生一次 | L1 |
| T-17 | `CalibrationRecord` 的 `macIdentity`／`device` 不符 → `notArmed`；未 armed 時 Policy 不 lock、不 wake | L1 |
| T-18 | Scanner 三通道：observation flood 不影響 sensor 事件抵達 | L3 |
| T-19 | `CoreBluetoothScanner` 並發呼叫 public API + 亂序 `FakeCentral` 回呼 → 事件序列合法 | L4-ish（package test） |

## 3. Fixtures：`Tests/Fixtures/BLE/`

- 格式：JSONL。第一行 metadata：`{"kind":"meta","macClass":"laptop|desktop","deviceClass":"iphone|watch|beacon","scenario":"...","recorder":"rssi-record x.y","anonymized":true}`；其後每行一個 `EngineInput`，`t` 為相對 `t0` 的毫秒整數。
- 匿名化：`DeviceID` → `device-A`／`device-B`；不含序號、MAC、名稱、wall-clock。
- **MVP 2 前為合成檔**：`stable-near`、`stable-away`、`walking-away`、`walking-back`、`signal-spike`、`device-lost`、`bluetooth-off`、`departure-then-silent`、`sudden-silence-at-desk`、`wake-after-sleep`、`wifi-interference`。
- **MVP 1B** 以 `Tools/rssi-record` 實錄取代；合成檔保留為最小回歸集。
- 每次修改引擎必須全部 replay 通過；replay 期望值以 golden transition 序列存於同名 `.expected.json`。

## 4. 實機測試矩陣

| 分級 | 內容 |
|---|---|
| **Required for MVP** | Apple Silicon × macOS 26 × iPhone × {Password, Touch ID} × {awake, screen locked, display sleep, system sleep} |
| **Required before v1** | + macOS 14、15；Apple Watch；Intel；screen saver；fast user switching |
| **Nice to have** | generic beacon 多品牌；多使用者帳號；AirPods（觀察） |

## 5. CI
- `ci.yml`：`swift build` + `swift test`（macOS runner）；App target 的 `xcodebuild` 在 Xcode 可用的 runner 上執行（MVP 0 標記 allow-failure 直到本機也能驗證）。
- `macos-beta.yml`：每週對最新 beta 跑一次。
- 覆蓋率目標：`ThresholdDomain` ≥ 90%（MVP 2 起量測）。
