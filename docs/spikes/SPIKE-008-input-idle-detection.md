# SPIKE-008 Input Idle Detection
Status: PARTIAL（2026-09-02：首次嘗試工具缺陷無效；探針修正後有一筆觀察）　Priority: 2（silence policy 前）

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

### 探針修正後的觀察（2026-09-02 14:46 UTC）

`screen-state` 改用 `CGEventType(rawValue: ~0)`（commit 1f9de4b）後，在使用者閒置且螢幕鎖定、顯示器剛被 `IOPMAssertionDeclareUserActivity` 點亮的狀態下跑 6 s：

| stateID | 回傳 idle | 對照 |
|---|---|---|
| `.hidSystemState` | 810 s | `ioreg -c IOHIDSystem` HIDIdleTime 同時刻 ≈ 826 s（一致） |
| `.combinedSessionState` | 18 s | 前一次 `IOPMAssertionDeclareUserActivity` 呼叫發生於約 18 s 前 |

**發現**：`combinedSessionState` 會被 `IOPMAssertionDeclareUserActivity` 重置——那正是本產品 `MacOSWakeController` 要呼叫的 API。若 `InputActivityProviding` 用 `combinedSessionState`，App 自己的 wake 會把 idle 歸零，污染 silence lock 的 supporting evidence。`hidSystemState` 反映真實 HID 閒置，且在鎖定畫面下仍可讀（免權限）。
**決定（暫定）**：`MacOSInputActivityProvider` 使用 `.hidSystemState`。仍未測：打字／滑鼠時是否即時歸零、synthetic `CGEvent` 是否計入、screen saver／fast user switching 下的值——這些需要使用者在場，狀態維持 PARTIAL。
