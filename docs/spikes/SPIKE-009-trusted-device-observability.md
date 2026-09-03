# SPIKE-009 Trusted Device Observability
Status: PARTIAL — 2026-09-03（Apple Watch／iPad：CONDITIONAL；iPhone：UNKNOWN；beacon：未測）　Priority: 1（MVP 1A 前的 GO/NO-GO 閘門）　ADR: ADR-009

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

## Evidence（2026-09-02）

### 環境
Apple Silicon（arm64）Mac，macOS 26.6.2（build 25G83；由事後 `sw_vers` 取得，工具本身未記錄版本）。一般住家／辦公室無線環境，Mac 全程保持清醒、螢幕大多亮著。受測裝置的距離、螢幕狀態、鎖定狀態、idle 時間**皆未控制也未記錄**。

### 工具與回合
Throwaway CLI `Tools/spikes/ble-observe`（非規格中的 `Tools/spikes/009/`），`scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`，JSONL 輸出。

| 回合 | 長度 | 說明 |
|---|---|---|
| run1 | 60 s | 當日第一次啟動 scanner process |
| run2 | 600 s | run1 結束後約 53 s 啟動的**另一個** process |

工具只把每個 identifier 的**前 3 筆** discover 明細寫進 JSONL，其餘只進每 10 s 的累計 summary。以下所有「每 10 s」數字均由相鄰 summary 的 count 差分還原。

### 掃描總體（run2，600 s）

| 指標 | 值 |
|---|---|
| 廣播筆數總計 | 13 841 |
| 唯一 `CBPeripheral.identifier` 數 | 56 |
| 首個 10 s 視窗即出現的 identifier | 25 |
| 其後陸續新增的 identifier | 31 |
| 每 10 s 視窗活躍 identifier 數 | 平均 22.0（17–32） |
| 每 10 s 視窗廣播筆數 | 中位數 167（135–770） |

identifier 生命期（首見→末見）分佈：

| 生命期 | 個數 |
|---|---|
| < 10 s | 12 |
| 10–60 s | 2 |
| 60–300 s | 16 |
| 300–540 s | 8 |
| ≥ 540 s | 18 |

即：56 個 identifier 中 18 個橫跨幾乎整段 600 s，12 個是只出現數秒的短命 identifier。**在這 10 分鐘的視窗內未觀察到「大量 identifier 快速輪替」**；長度 600 s 短於 Apple 裝置隨機位址輪替的一般週期，因此本回合**不能**回答輪替率問題。

### 有廣播名稱的裝置（run2；一律以代號稱呼）

裝置類別由廣播名稱推定，未以其他方式交叉驗證。

| 代號 | 推定類別 | 廣播筆數 | 每 10 s 中位數 | 有樣本的 10 s 視窗 | RSSI 中位／最低 |
|---|---|---|---|---|---|
| A | iPhone（同 Apple ID） | 623 | 8 | 60/60（100%） | −46 ／ −65 |
| B | Apple Watch（同 Apple ID） | 622 | 8 | 60/60（100%） | −58 ／ −83 |
| C | iPad（同 Apple ID） | 575 | 8 | 60/60（100%） | −56 ／ −89 |
| D | 另一台 Mac（同 Apple ID） | 617 | 0 | 20/60（33%） | −59 ／ −85 |
| E | AirPods | 80 | 0 | 29/60（48%） | −63 ／ −81 |
| F | 常駐 Apple 家用裝置 | 4 982 | 65 | 60/60（100%） | −58 ／ −93 |
| G–K | 5 個非 Apple 週邊 | 44–953 | 0–12.5 | 27%–100% | −88 ～ −97 |

裝置 D 最長連續 12 個 10 s 視窗（≥ 120 s）沒有任何廣播，之後又恢復。
manufacturer data 前兩位元組為 `4C 00`（Apple）的 identifier：run2 有 44 個、run1 有 24 個。
**RSSI 的 `max` 欄不可用**：56 個 identifier 中有 5 個的 max 為 `127`，即 CoreBluetooth「數值不可用」哨兵值，工具未過濾。中位數與最小值不受影響。

### Identity stability（僅涵蓋 scanner process restart）

| 指標 | 值 |
|---|---|
| run1 唯一 identifier | 31 |
| run2 唯一 identifier | 56 |
| 交集 | 29 |
| run1 有而 run2 無 | 2（各只有 1 筆廣播） |
| run1 廣播筆數中屬於交集 identifier 的比例 | 99.9% |
| 11 個有廣播名稱的裝置，兩回合 identifier 相同 | 11/11 |

兩個 process 相隔約 53 s。**這只驗證了 B 節情境中的 scanner restart 一項。**

### 第三批：1 小時 presence suitability + 19 小時 identity（2026-09-03 13:42–14:42 CST，自動化執行）

環境：同一台 Mac，使用者在座（HIDIdleTime < 2 min 起跑），裝置位置**未控制也未記錄**（RSSI 中位數 −56～−58 dBm，與前日桌上量測一致，推定在座位附近）。兩個 process 同時錄製：`Tools/rssi-record record --device ×3 --seconds 3600`（production `CoreBluetoothScanner`）與 `ble-observe 3600`。

**§C Presence suitability（rssi-record，10 s 視窗，361 個）**

| 代號 | 類別 | 樣本 | receiving 比例 | 最長 silent gap | RSSI 中位／MAD | RSSI 127 丟棄 |
|---|---|---|---|---|---|---|
| B | Apple Watch（同 Apple ID） | 4 814 | **100%**（361/361） | **6.9 s** | −58 ／ 2 dB | 5 |
| C | iPad（同 Apple ID） | 3 317 | **100%**（361/361） | **9.9 s** | −56 ／ 0 dB | 3 |
| A | iPhone（前日 identifier） | 0 | 0% | 3 606 s（整段） | — | — |

B、C 在此放置下達到成功條件的「≥ 95%、最長 gap ≤ 10 s」；C 的 9.9 s 貼近上限。1 m／3 m／8 m 三段距離**未分段量測**。

**§B Identity（ble-observe，360 個視窗，137 個 identifier）**

| 指標 | 值 |
|---|---|
| 前日（2026-09-02 14:xx）identifier 於 2026-09-03 13:42 仍相同 | Apple Watch ✔、iPad ✔、另一台 Mac ✔、常駐家用裝置 ✔（≈ 19 h，含 Mac 夜間 display sleep，無 reboot） |
| 前日 iPhone identifier | **整小時未出現**；亦無任何廣播 iPhone 名稱的新 identifier |
| identifier 生命期 | ≥ 3 000 s：11；600–3 000 s：67；60–600 s：37；< 60 s：22 |

iPhone 的缺席**無法歸因**：可能不在附近、藍牙關閉、或 identifier 已輪替且不再廣播名稱。本回合對 iPhone 沒有任何證據，前一批的 600 s 觀察仍是唯一資料。

**依本文件成功條件的判定（2026-09-03）**

| 類別 | 判定 | 條件／缺口 |
|---|---|---|
| Apple Watch | **CONDITIONAL** | 條件：同 Apple ID、佩戴中、位於座位附近。缺：B 的 reboot／BT off→on／forget-re-pair；C 的 3 m／8 m 分段；A 的整個矩陣 |
| iPad | **CONDITIONAL** | 同上；gap 9.9 s 貼近上限，3 m 以上需驗證 |
| iPhone | **UNKNOWN** | 600 s 內連續可觀察（前日）；identifier 跨日穩定性**未證實**；1 h suitability 未取得 |
| Generic beacon | UNKNOWN | 未測 |

檔案：`Tools/spikes/out/desk-uncontrolled-1h.jsonl`（匿名化 fixture，無 profile，故不配 golden）、`identity-1h.jsonl`（gitignored）。

### Not yet measured

對應本文件自己的實驗章節：

- **A. Device Discovery**：情境矩陣（Mac 螢幕亮／滅 × 裝置螢幕亮／滅 × 裝置鎖定／未鎖 × 裝置 idle 5／30／60 min × 口袋／桌上）**完全未跑**。首筆延遲、「是否需要 companion app」「是否需要已知 service UUID」未單獨驗證（本回合以 `withServices: nil` 掃描，並未反證需要 service UUID 的情形）。
- **B. Identity Stability**：App restart、Mac reboot、iPhone reboot、Mac 端 BT off→on、iPhone 端 BT off→on、OS update、forget／re-pair、24 小時 idle —— **全部未測**。
- **C. Presence Suitability**：1 小時連續、桌上 1 m／口袋 3 m／隔壁房間 8 m 各 20 分鐘 —— 未測。距離未記錄。RSSI 的 MAD 未計算（工具只輸出 median／min／max）。
- **最長 silent gap**：只能得到上界。每個 10 s 視窗都有樣本，故 gap **< 20 s**；由於工具不保留逐筆時間戳，**無法驗證成功條件要求的 ≤ 10 s**。
- **Generic BLE beacon（iBeacon／AltBeacon）**：未測。
- **AirPods**：只有被動觀察，未區分「連到 iPhone／連到 Mac／收在盒中」。
- **環境矩陣**：只有一台 Apple Silicon Mac × macOS 26。Intel、macOS 14／15、不同 Apple ID 的 iPhone 皆未測。

### Preliminary reading

尚無 GO/NO-GO。成功條件無一項被完整滿足。目前資料**只**支持以下敘述：

1. 以 `withServices: nil` + `allowDuplicates: true` 掃描時，同 Apple ID 的 iPhone、Apple Watch、iPad 在 600 s 內以約 0.8–1.0 筆/秒的節奏持續被回報，每個 10 s 視窗都有樣本，全程不需 companion app、不需事先知道 service UUID、不需連線。
2. 同一台 Mac 上兩個相隔 53 s 的獨立 scanner process 取得的 `CBPeripheral.identifier` 對所有具名裝置一致。這是 identifier 穩定性最弱的一種驗證，不能外推到 reboot 或 24 小時尺度。
3. 同一房間內同時存在數十個 identifier（每 10 s 視窗平均 22 個活躍），其中約五分之一是生命期 < 10 s 的短命 identifier。`DeviceRegistry` 與 discovery UI 必須能承受這個量級的雜訊，且不能假設每個 identifier 都對應一個持續存在的裝置。
4. 同一台 Mac（裝置 D）與 AirPods（裝置 E）的可觀察性明顯較差（33%／48% 的視窗有樣本，D 有一段 ≥ 120 s 的空窗）。若未來要支援這兩類裝置，需要獨立驗證。

決定 supported list 之前，至少必須補完 B 節的 reboot／BT off→on 與 C 節的距離矩陣。
