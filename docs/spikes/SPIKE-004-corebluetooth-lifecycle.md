# SPIKE-004 CoreBluetooth Lifecycle
Status: PARTIAL — 2026-09-03（display sleep 與 BT off→on 已實測 GO；system sleep／App Nap／24 h 未測）　Priority: 1（與 SPIKE-009 同批）

## Question
`CBCentralManager` 在 display sleep、system sleep／wake、Bluetooth off／on、App Nap、長時間執行下的狀態序列與掃描行為為何？wake 後是否需重呼叫 `scanForPeripherals`？

## Why it matters
決定 `CoreBluetoothScanner.pause()/resume()` 的實作、`SensorHealth` 的映射、`reset(.systemWake)` 的時機，以及 diagnostics 中 sensor transition 的解讀。

## Experiment
同 SPIKE-009 的 CLI 加上：記錄每次 `centralManagerDidUpdateState` 的 (t, state)、掃描是否自動恢復、wake 後首筆 observation 延遲。情境：display sleep 10 min；system sleep 10 min（合蓋／`pmset sleepnow`）；BT off→on；App Nap（App 在背景 30 min，Info.plist 不停用 App Nap vs 停用）；連續執行 24 h。

## Environment matrix
Required：Apple Silicon × macOS 26。Before v1：Intel、macOS 14／15。

## Expected evidence
狀態序列時間表；display sleep 下掃描是否持續（樣本率是否下降）；system sleep 前後是否出現 `.resetting`；wake 後是否需重掃、延遲多少。

## Success criteria
GO：行為可預測且可用 supported API 恢復（重呼叫 scan 即可）；display sleep 下掃描持續。
CONDITIONAL GO：需停用 App Nap 或其他可接受的 Info.plist 設定。
NO-GO：display sleep 下掃描停止且無法恢復（Wake on Return 失去前提）。

## Decision resulting from outcome
寫入 `bluetooth.md` §4 的 resume 行為、`system-integration.md` §4 表格的「預期」欄改為「實測」。

## Evidence（2026-09-02）

### 環境
Apple Silicon（arm64）Mac，macOS 26.6.2（build 25G83；由事後 `sw_vers` 取得，工具未記錄版本）。**Mac 全程保持清醒**；本回合沒有任何 display sleep（10 分鐘級）或 system sleep 情境。

### 工具與回合
與 SPIKE-009 同一支 CLI（`Tools/spikes/ble-observe`）。每 10 s 記錄一次 `isScanning` 與 `CBManagerState`，並在 `centralManagerDidUpdateState` 每次觸發時記錄 (t, state)。

### 狀態序列

| 指標 | run1（60 s） | run2（600 s） |
|---|---|---|
| `CBCentralManager` 建立當下的 `state` | 0（`.unknown`） | 0（`.unknown`） |
| 第一次 `centralManagerDidUpdateState` | t = 3 037 ms，state 5（`.poweredOn`） | t = 59 ms，state 5（`.poweredOn`） |
| `centralManagerDidUpdateState` 觸發總次數 | 1 | 1 |
| tick 數 | 6 | 60 |
| tick 中 `state == .poweredOn` | 6/6 | 60/60 |
| tick 中 `isScanning == true` | 6/6 | 60/60 |
| 出現 `.resetting`／`.poweredOff`／`.unauthorized` | 0 | 0 |

`.unknown → .poweredOn` 的延遲在兩回合差距很大（3 037 ms vs 59 ms）。run1 是當日第一次啟動該執行檔，**但工具沒有記錄是否出現藍牙權限對話**，因此不能宣稱差異的成因。實作上唯一能推出的要求是：`CBCentralManager` 建立後必須容忍數秒的 `.unknown`，不能同步假設已 `poweredOn`。

### 一段推算出來的短暫鎖定／顯示器睡眠重疊（不構成 display sleep 證據）

依輸出檔的 mtime 推算，SPIKE-001／007 的兩回合 `screen-state` 落在 run2 的區間內（約 elapsed 66–186 s 與 242–317 s），期間發生一次約 4 s 的螢幕鎖定與一次約 0.55 s 的顯示器睡眠；該期間 run2 的 `isScanning` 未變、廣播持續。**此對齊來自檔案時間戳推算而非任一工具記錄，且 0.55 s 遠短於本 spike 要求的 10 分鐘**，僅供參考，不作為 display sleep 下掃描是否持續的證據。

### 第二批：display sleep 75 s 下的掃描（2026-09-02 14:48 UTC，自動化執行）

環境同上；螢幕已鎖定、接 AC、system sleep 被阻止。`ble-observe 90`，於第 15 s 以 `pmset displaysleepnow` 讓顯示器睡眠，之後 75 s 顯示器保持睡眠（無人輸入）。

| 10 s 視窗結束 | 廣播筆數 | 活躍 identifier | 最高頻裝置筆數 |
|---|---|---|---|
| 10 s（亮） | 140 | 21 | 63 |
| 20 s（15 s 起睡眠） | 143 | 18 | 60 |
| 30 s | 159 | 19 | 54 |
| 40 s | 167 | 17 | 55 |
| 50 s | 163 | 22 | 59 |
| 60 s | 166 | 23 | 68 |
| 70 s | 158 | 20 | 67 |
| 80 s | 144 | 18 | 54 |
| 90 s | 148 | 21 | 52 |

- `centralManagerDidUpdateState` 只在啟動時出現一次（`.poweredOn` 於 22 ms）；display sleep 前後**沒有任何** state 事件、沒有 `.resetting`。
- 9/9 個 tick `isScanning == true`；廣播筆數與活躍 identifier 數在顯示器睡眠前後無可辨差異（無需重呼叫 `scanForPeripherals`）。
- 限制：75 s，不是規格的 10 min；process 為前景 CLI（非 App Nap 情境）。
- 檔案：`Tools/spikes/out/spike004-displaysleep.jsonl`、`spike004-cmds.jsonl`（gitignored）。

### 第三批：display sleep 136 s（2026-09-02 14:51 UTC，自動化執行，原訂 10 min）

`ble-observe 600` + `screen-state 605` 同時記錄；第 2 s `pmset displaysleepnow`。顯示器於 t 7 ms 睡眠、**t 136.6 s 由使用者回座喚醒並解鎖**（137.3 s `com.apple.screenIsUnlocked`），故 display sleep 實際 136 s，之後 464 s 為使用者正常使用。

| 指標 | 值 |
|---|---|
| `centralManagerDidUpdateState` | 只有啟動時 `.poweredOn`（26 ms）；display sleep／wake／unlock 全程無 state 事件 |
| tick 60/60 | `isScanning == true`、`.poweredOn` |
| 每 10 s 廣播筆數 | min 137、中位數 166、max 777（含使用者回座後）；睡眠中的 13 個視窗與清醒視窗無差異 |
| 唯一 identifier | 62 |
| 有名稱裝置 | 5 個在 60/60 視窗有樣本（每 10 s 中位數 8–61 筆）；1 個間歇（18/60） |

檔案：`Tools/spikes/out/spike004-10min.jsonl`、`spike004-10min-screen.jsonl`（gitignored）。

### Not yet measured

對應本文件的實驗章節，以下**全部未跑**：

- display sleep **10 min** 下掃描是否持續（已有 75 s + 136 s 兩段證據：持續、樣本率不變、無 state 事件；10 min 連續段因使用者回座中斷）
- system sleep 10 min（合蓋／`pmset sleepnow`）前後的狀態序列，是否出現 `.resetting`
- wake 後是否需要重呼叫 `scanForPeripherals`、wake 後首筆 observation 延遲
- Bluetooth off→on
- App Nap（背景 30 min；Info.plist 停用 vs 不停用）
- 連續執行 24 h
- Intel、macOS 14／15

### Preliminary reading

尚無 GO/NO-GO。成功條件之一「display sleep 下掃描持續」已有 75 s 的直接證據（持續、無 state 事件、樣本率不變），朝 GO；「system sleep／wake 後可用 supported API 恢復」與 BT off→on、App Nap、24 h 仍未測。`CoreBluetoothScanner.resume()` 目前一律重呼叫 `scanForPeripherals`（保守；重複呼叫無害），待 system sleep 情境後定案。

目前只能說：在 Mac 保持清醒、單一 process 連續執行 10 分鐘的條件下，`CBCentralManager` 的狀態序列是 `.unknown → .poweredOn` 一次到位，之後 60 個 10 s 取樣點全部維持 `.poweredOn` 且 `isScanning == true`，未出現任何降級狀態。這支持 `bluetooth.md` §3 的狀態映射在正常路徑上可用，但**完全不支持** `pause()`／`resume()` 與 `reset(.systemWake)` 的任何設計選擇。

`system-integration.md` §4 表格與 `bluetooth.md` §4 的 resume 行為維持「預期」，不改為「實測」。

## Evidence 補充：Bluetooth off→on（2026-09-03 21:17 CST，實機）

本 spike 的 Experiment 列了四種情境；2026-09-02 那批涵蓋 display sleep（75 s 與 136 s 掃描持續）與 10 分鐘連續執行。**BT off→on 這一項在此補上**，由操作者在一段 180 s 的 `rssi-record record` 期間手動切換 Mac 控制中心的藍牙開關。

環境：MacBook Pro（`Mac17,2`，M5），macOS 26.6.2（25G83），production `CoreBluetoothScanner`。

| t | `centralManagerDidUpdateState` 映射後的 `SensorHealth` 事件 | 動作 |
|---|---|---|
| 0.023 s | `available` | 掃描開始 |
| 40.448 s | `unavailable.poweredOff` | 使用者關閉 Mac 藍牙 |
| 76.051 s | `available` | 使用者開啟 Mac 藍牙 |

實測到的行為：

1. **狀態序列可預測**：`poweredOn → poweredOff → poweredOn`，沒有中間的 `.resetting`，也沒有 `.unauthorized` 誤報。
2. **不需重呼叫 `scanForPeripherals`**：`CoreBluetoothScanner` 在 `poweredOn` 回來後自行恢復掃描，呼叫端沒有做任何事。
3. **恢復延遲**：射頻恢復到第一筆 observation 約 6 s（t=76.1 s 事件，t≈82 s 的視窗已累積 34 筆新樣本）。
4. **identifier 不變**：中斷前後為同一個 `CBPeripheral.identifier`，不需重新配對或重新選擇 trusted device。
5. **空窗被正確歸因**：這 35.6 s 完全反映為 sensor 軸的 `unavailable.poweredOff`，而不是 device 軸的 silence。presence 軸在 `SensorHealth != .healthy` 期間不前進（`ProximityEngine.evaluatePresence`），Policy 因此拒絕行動。

依本文件的 Success criteria，BT off→on 這一項達到 **GO**（行為可預測，且不需要任何額外呼叫即可恢復）。整份 spike 仍為 PARTIAL：system sleep 10 min、App Nap 30 min、連續 24 h 三項未測。

檔案：`Tools/spikes/out/iphone/bluetooth-off.jsonl`（gitignored）。詳見 SPIKE-009「第五批」。
