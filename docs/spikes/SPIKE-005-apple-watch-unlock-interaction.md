# SPIKE-005 Apple Watch Unlock Interaction
Status: CONDITIONAL GO（掃描不干擾）— 2026-09-03；App 點亮路徑未測　Priority: 3（MVP 4 前）

## Question
本 App 以 assertion 點亮螢幕後，macOS 的 Apple Watch 自動解鎖是否照常觸發？我們的 BLE 掃描是否干擾 Watch 解鎖的藍牙流程？Watch 解鎖後 `ScreenState` 的通知序列為何？

## Why it matters
主線承諾「Watch 使用者零動作解鎖」；若掃描干擾或點亮方式不觸發 Watch 流程，承諾不成立。

## Experiment
Watch 解鎖開啟；情境：手動按鍵點亮 vs 本 App 點亮，各 30 次；掃描開／關各半；記錄 Watch 解鎖成功率、延遲、SPIKE-001 工具的狀態序列。

## Success criteria
GO：本 App 點亮時 Watch 解鎖成功率與手動點亮無顯著差異（±5%），掃描不影響。
CONDITIONAL GO：需在點亮後暫停掃描 N 秒。
NO-GO：本 App 點亮時 Watch 解鎖不觸發 → 產品語意改為「螢幕已亮，請抬腕／碰 Touch ID」。

## Decision resulting from outcome
`WakeController` 後是否暫停掃描；README 用語。

## Evidence（2026-09-03 21:33–21:39 CST）

### 環境
MacBook Pro（`Mac17,2`，Apple M5），macOS 26.6.2（25G83）。系統「要求密碼」＝立即。Apple Watch 同 Apple ID、全程配戴於手腕。觸發：`pmset displaysleepnow`（同 SPIKE-007，非 IOKit `IORequestIdle`）。以 `Tools/spikes/screen-state` 記錄 `com.apple.screenIsLocked`／`com.apple.screenIsUnlocked` 通知與 `CGDisplayIsAsleep` 輪詢。

### 結果：9/9 成功，0 失敗

| trial | 本 App 掃描中？ | displaySleep→locked | displayWake→unlocked | locked→unlocked 總長 |
|---|---|---|---|---|
| 1 | 否 | 70 ms | 2 296 ms | 32 961 ms（含人為等待） |
| 2 | 否 | 89 ms | 1 822 ms | 34 324 ms（含人為等待） |
| 3 | 否 | 81 ms | 2 821 ms | 3 077 ms |
| 4 | 否 | 337 ms | 2 157 ms | 2 157 ms |
| 5 | 否 | 89 ms | 1 696 ms | 3 922 ms |
| 6 | 否 | 79 ms | 2 006 ms | 10 893 ms |
| 7 | 否 | 65 ms | 2 127 ms | 6 941 ms |
| 8 | **是**（`rssi-record record`，production scanner） | 96 ms | 1 902 ms | 10 540 ms |
| 9 | **是** | 94 ms | 1 864 ms | 11 213 ms |

`displayWake→unlocked` 是顯示器點亮到 `com.apple.screenIsUnlocked` 通知抵達的延遲——即 Watch 完成 BLE 認證所需的時間，落在 1.7–2.8 s，與 `locked→unlocked` 總長（含使用者反應時間）分開列出。trial 3–9 之間的間隔僅 5–14 s：Watch 一旦戴著且先前已認證過，重新鎖定後不需要重新抬腕，會在無使用者主動動作下於數秒內自動重新解鎖——這是本次測試才發現的行為，規格原先假設「每次都手動抬腕」。

Trial 8、9 在本 App 的 `Tools/rssi-record record`（即 production `CoreBluetoothScanner`，`scanForPeripherals(withServices: nil, allowDuplicates: true)`）**同時執行**下完成，掃描全程未中斷（trial 8、9 期間的 fixture `device-locked-idle-30m.jsonl` 顯示 receiving 100%），Watch 解鎖延遲（1 902 ms、1 864 ms）與無掃描時（trial 3–7：1 696–2 821 ms）無顯著差異。

### 判定：CONDITIONAL GO → 傾向 GO

依本文件成功條件：「本 App 點亮時 Watch 解鎖成功率與手動點亮無顯著差異（±5%），掃描不影響」。本次全部 9 次觸發皆為 `pmset displaysleepnow`（點亮方式的手動／App 對照未分開測），但**掃描開／關的對照組已直接測得**：9/9 成功，掃描中的 2 次延遲落在無掃描 5 次的分佈範圍內，未觀察到干擾。

未達規格要求的 30 次（手動點亮 vs 本 App 點亮各 30 次）；n=9 屬初步證據。**掃描不影響解鎖**這一項可視為 GO；「本 App 點亮是否等同手動點亮」仍待驗證——本次全部由 `pmset displaysleepnow` 觸發，尚未用 `IOPMAssertionDeclareUserActivity`（`Tools/spikes/wake-display`）點亮後測試 Watch 解鎖。

### Not yet measured
- 本 App 實際點亮方式（`IOPMAssertionDeclareUserActivity`）觸發後的 Watch 解鎖（本次全部經 `pmset displaysleepnow`）
- 手動點亮 vs App 點亮的正式對照（各 30 次）
- 「要求密碼」5 秒／關閉兩組設定
- macOS 14／15、Intel

檔案：`Tools/spikes/out/screen-run-unlock.jsonl`（gitignored，無 UUID／裝置名稱，僅 lock/unlock 通知與 idle 秒數）。
