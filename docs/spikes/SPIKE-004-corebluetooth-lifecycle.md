# SPIKE-004 CoreBluetooth Lifecycle
Status: NOT RUN　Priority: 1（與 SPIKE-009 同批）

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
