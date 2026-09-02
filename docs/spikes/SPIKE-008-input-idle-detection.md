# SPIKE-008 Input Idle Detection
Status: NOT RUN（2026-09-02 曾嘗試，工具缺陷導致資料無效）　Priority: 2（silence policy 前）

## Question
`CGEventSource.secondsSinceLastEventType(_:eventType:)` 用哪個 `stateID`（`.hidSystemState`／`.combinedSessionState`）、是否計入 synthetic event、在 lock screen／screen saver／display sleep／fast user switching 下回傳什麼、是否真的不需要 Accessibility？

## Why it matters
`inputIdle` 是 silence-based lock 的唯一 supporting evidence，也是 measuredFar 的誤鎖守衛；錯誤值會讓人在打字時被鎖，或讓 silence lock 永遠不觸發。

## Experiment
每 500 ms 輪詢兩種 stateID，記錄值；情境：正常打字／滑鼠、閒置 5 min、鎖定畫面下打字、screen saver、display sleep、fast user switching 後、以 `CGEvent` 送 synthetic 事件、未授權 Accessibility 的乾淨帳號。

## Success criteria
GO：存在一個 stateID 在所有情境下語意一致、免權限、不計 synthetic 事件。
CONDITIONAL GO：部分情境回傳無意義值但可辨識（provider 回 nil）。
NO-GO：需要 Accessibility 或值不可信 → silence lock 停用（`silenceLock = .never` 為預設）。

## Decision resulting from outcome
`MacOSInputActivityProvider` 的實作與 nil 條件；`PolicySettings.silenceLock` 預設值。

## Evidence（2026-09-02）

**本 spike 沒有取得任何有效資料，Status 維持 NOT RUN。**

### 工具缺陷

`Tools/spikes/screen-state` 呼叫的是：

```swift
CGEventSource.secondsSinceLastEventType(.hidSystemState,      eventType: .null)
CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
```

`CGEventType.null` 的 rawValue 是 `0`（`kCGEventNull`），**不是** `kCGAnyInputEventType`（rawValue `UInt32.max`）。因此這兩個呼叫量的是「距上次 **null 事件**的秒數」，而 null 事件不會因為使用者輸入而產生。回傳值與「距上次輸入的秒數」無關。

修正方式：

```swift
let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
```

### 資料如何佐證這個缺陷

screen-run1（120 s，24 個樣本）與 screen-run2（75 s，15 個樣本）中，兩個 stateID 都是嚴格單調遞增、斜率恰為 1.000 s/s（run1：Δcounter 114.994 s ÷ Δt 114.995 s），相鄰樣本差值一律 4.996–5.003 s，全程 0 次下降。screen-run1 起始時 `hidSystemState` 已是 12 133 s、`combinedSessionState` 已是 25 621 s，但當下使用者正在終端機操作以啟動這支工具。

這兩件事只用來證明**探針量錯了對象**。這些數列裡不包含任何關於 `.hidSystemState` 與 `.combinedSessionState` 語意差異、鎖定畫面行為、synthetic event、或權限需求的資訊，**不得**由此推論任何結論。

### Not yet measured

本文件實驗章節的每一項情境都仍未取得有效資料：正常打字／滑鼠、閒置 5 min、鎖定畫面下打字、screen saver、display sleep、fast user switching 後、`CGEvent` synthetic 事件、未授權 Accessibility 的乾淨帳號。兩個 stateID 的比較也未進行。

### 下一步

以 `CGEventType(rawValue: ~0)` 重寫探針後，重跑全部情境。在此之前 `system-integration.md` §1 的保守方向不變：`InputActivityProviding` 的 `inputIdle` 一律回 nil，Policy 不依賴它，`PolicySettings.silenceLock` 不改為預設啟用。
