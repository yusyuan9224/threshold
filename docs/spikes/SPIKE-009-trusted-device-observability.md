# SPIKE-009 Trusted Device Observability
Status: NOT RUN　Priority: 1（MVP 1A 前的 GO/NO-GO 閘門）　ADR: ADR-009

## Question
透過 CoreBluetooth 的 supported API（`scanForPeripherals(withServices: nil, allowDuplicates: true)`），iPhone／Apple Watch／generic BLE beacon（AirPods 僅觀察）能否**長時間、穩定**地作為 proximity source，且其 `CBPeripheral.identifier` 是否跨生命週期穩定？

## Why it matters
整個產品的 supported device list、onboarding、README、行銷用語、DeviceRegistry、calibration 與 MVP 1 exit criteria 都建立在這個假設上。BLEUnlock 以 private 資料庫與 Active 連線補強，我們不採用。若 NO-GO，改 supported device 策略，不硬救。

## Experiment
Throwaway CLI（`Tools/spikes/009/`）：啟動 central、掃描、對每個 identifier 記錄 (t, rssi, advertisedName?, manufacturerData 長度, serviceUUIDs?)，以 JSONL 輸出。

### A. Device Discovery（每種裝置各自跑）
情境矩陣：Mac 螢幕亮／滅 × 裝置螢幕亮／滅 × 裝置鎖定／未鎖 × 裝置 idle 5／30／60 min × 裝置在口袋／桌上。
記錄：是否被發現、首筆延遲、advertisement cadence（每分鐘筆數）、RSSI callback 頻率、是否需要 companion app、是否需要已知 service UUID 才掃得到。

### B. Identity Stability
對同一裝置記錄 identifier，經歷：scanner restart、App restart、Mac reboot、iPhone reboot、Bluetooth off→on（Mac）、Bluetooth off→on（iPhone）、OS update（若可）、forget／re-pair、24 小時 idle。每次比對 identifier 是否相同。

### C. Presence Suitability
連續 1 小時，裝置置於桌上 1 m、口袋 3 m、隔壁房間 8 m 各 20 分鐘。計算：receiving 比例（每 10 s 視窗內有樣本的比例）、最長 silent gap、RSSI 中位數與 MAD。

## Environment matrix
Required：Apple Silicon Mac × macOS 26 × iPhone（同 Apple ID）。
Before v1：Apple Watch；Intel Mac；macOS 14／15；不同 Apple ID 的 iPhone；generic beacon（至少一個 iBeacon/AltBeacon）。
觀察：AirPods（連到 iPhone／連到 Mac／收在盒中）。

## Expected evidence
每種裝置一張表：可發現性條件、cadence、identifier 穩定性紀錄、1 小時 receiving 比例與最長 gap。

## Success criteria（每種裝置）
- SUPPORTED：無需 companion／service UUID；identifier 在 B 的所有情境穩定；C 的 receiving 比例 ≥ 95%、最長 gap ≤ 10 s（在 1 m 與 3 m）
- CONDITIONAL：有明確條件下達標（例如需同 Apple ID、需裝置未鎖），條件可在 onboarding 說明
- UNSUITABLE：任一項不達標且無合理條件
- UNKNOWN：未測

## Failure criteria
iPhone 與 Apple Watch 皆 UNSUITABLE。

## Decision resulting from outcome
- iPhone SUPPORTED/CONDITIONAL → MVP 1A 照計畫。
- iPhone UNSUITABLE、beacon SUPPORTED → MVP 支援 generic／明確廣播裝置；iPhone 留待 companion app（新 ADR）。
- 全部 UNSUITABLE → 停止 BLE 路線；重新評估 presence transport（新 brainstorming）。
結果寫回 README supported list、`bluetooth.md` §1、`EngineConfiguration` 的 silentThreshold／evidenceTimeout 初始值。
