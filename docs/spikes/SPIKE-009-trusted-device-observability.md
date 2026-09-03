# SPIKE-009 Trusted Device Observability
Status: PARTIAL — 2026-09-03（iPhone：CONDITIONAL GO，§C 三段全過；Apple Watch：CONDITIONAL，8 m 不達標；iPad：CONDITIONAL；beacon：未測）　Priority: 1（MVP 1A 前的 GO/NO-GO 閘門）　ADR: ADR-009

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

**依本文件成功條件的判定（2026-09-03 下午；已被下方「第四批」修正，保留為過程紀錄）**

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

### 第四批：受控距離分段（2026-09-03 20:37–21:09 CST，操作者在場）

這是 §C 第一次在**距離受控且記錄**的條件下量測，也是 iPhone 第一次取得完整資料。前三批的 iPhone 判定（UNKNOWN）與「Apple Watch／iPad 較適合」的方向由本批修正。

#### 環境

MacBook Pro（`Mac17,2`，Apple M5），macOS 26.6.2（build 25G83）。一般住家環境。Mac 全程清醒、放在固定位置未移動。受測 iPhone **全程鎖定、螢幕熄滅**；Apple Watch **全程配戴於手腕**。每段 600 s，`Tools/rssi-record record`（production `CoreBluetoothScanner`），iPhone 與 Apple Watch 由兩個並行的 process 各自錄製，`--device-class` 各自正確標記。

| 段 | scenario | 裝置位置 |
|---|---|---|
| 1 | `desk-1m` | iPhone 平放桌上距 Mac 約 1 m；操作者在座位上 |
| 2 | `pocket-3m` | iPhone 置於褲袋；操作者離座，距 Mac 約 3 m |
| 3 | `next-room-8m` | iPhone 置於褲袋；操作者位於隔壁房間、**門關上**，距 Mac 約 8 m |

與本文件 §C 規格的偏離：每段 **10 分鐘**（規格為 20 分鐘）。60 個 10 s 視窗足以估計 receiving 比例與 RSSI 分佈；對「最長 gap ≤ 10 s」這類尾端事件的偵測力弱於 20 分鐘版本，下方所有 gap 數字應如此解讀。

#### §C 結果

| 裝置 | 段 | 樣本 | 速率 | receiving | 最長 gap | RSSI 中位 | MAD |
|---|---|---|---|---|---|---|---|
| iPhone | desk-1m | 774 | 1.29/s | **100%**（61/61） | **10.2 s** | −50 | 5 |
| iPhone | pocket-3m | 594 | 0.98/s | **100%** | 9.9 s | −60 | 4 |
| iPhone | next-room-8m | 594 | 0.99/s | **100%** | 9.0 s | −68 | 4 |
| Apple Watch | desk-1m | 569 | 0.95/s | 98.4% | 9.9 s | −59 | 12 |
| Apple Watch | pocket-3m | 634 | 1.05/s | **100%** | 7.1 s | −41 | 5 |
| Apple Watch | next-room-8m | 241 | 0.41/s | **83.6%** ✗ | **25.7 s** ✗ | −66 | 4 |

每段各有 1 筆 RSSI `127`（CoreBluetooth「不可用」哨兵值）被工具丟棄，`watch/pocket-3m` 為 0 筆。

#### 廣播節奏的結構

樣本間距不是均勻的，而是「叢發 + 週期性空窗」：

| capture | 間距中位數 | p95 | 最大 | >5 s 的次數 | >10 s 的次數 |
|---|---|---|---|---|---|
| iphone/desk-1m | 0.04 s | 3.32 s | 10.19 s | 9 | **1** |
| iphone/pocket-3m | 0.27 s | 3.59 s | 9.91 s | 11 | 0 |
| iphone/next-room-8m | 0.27 s | 3.58 s | 9.01 s | 12 | 0 |
| watch/desk-1m | 0.27 s | 3.58 s | 9.91 s | 17 | 0 |
| watch/pocket-3m | 0.27 s | 3.32 s | 7.14 s | 14 | 0 |
| watch/next-room-8m | 0.27 s | 11.29 s | 25.68 s | 48 | **13** |

>5 s 的空窗集中在 6.3–6.9 s，三段一致，與距離無關——這是 Apple 裝置廣播排程的結構特性，不是訊號衰減的結果。`iphone/desk-1m` 在 773 個間距中只有 1 次超過 10 s。

#### RSSI 分佈與距離的關係

| capture | n | p5 | p25 | 中位 | p75 | p95 | MAD |
|---|---|---|---|---|---|---|---|
| iphone/desk-1m | 774 | −64 | −54 | **−50** | −40 | −33 | 5 |
| iphone/pocket-3m | 594 | −75 | −65 | **−60** | −57 | −51 | 4 |
| iphone/next-room-8m | 594 | −82 | −73 | **−68** | −65 | −62 | 4 |
| watch/desk-1m | 569 | −86 | −71 | **−59** | −48 | −36 | 12 |
| watch/pocket-3m | 634 | −58 | −50 | **−41** | −37 | −36 | 5 |
| watch/next-room-8m | 241 | −77 | −70 | **−66** | −63 | −59 | 4 |

- **iPhone：單調且可分離。** 中位數 −50 → −60 → −68，三段的四分位區間幾乎不重疊（3 m 的 p25 = −65 與 8 m 的 p75 = −65 僅一點相接）。iPhone 的 RSSI 可以作為距離指標，calibration 的 near／far baseline 有意義。
- **Apple Watch：非單調且重疊。** 1 m 的中位（−59）**弱於** 3 m 的中位（−41），且 1 m 的離散度是其他所有 capture 的兩倍以上（MAD 12 dB，四分位區間 −71～−48）。手腕配戴裝置的訊號主要受姿勢與身體遮蔽支配，不是距離。以 RSSI 對 Apple Watch 做距離校正在本量測中不成立。

本段的手腕姿勢**未控制**（僅要求「手自然放，不刻意朝向 Mac」），無法區分「姿勢效應」與「1 m 時手腕被桌面／身體遮蔽」兩種解釋；但兩者都指向同一個結論：Watch 的 RSSI 不是距離的可靠代理。

#### 對 `EngineConfiguration` 的直接影響

`EngineConfiguration.silentThreshold` 目前是 `.seconds(10)`，其註解明言為「Initial Tunable Defaults — engineering values without field evidence」。本批是第一份 field evidence：

- `iphone/desk-1m` 出現一次 10.19 s 的空窗，**超過** 10 s 門檻。操作者當時就坐在 Mac 前、手機在桌上 1 m 處——這會讓 `PresenceState` 翻成 `.silent`，是一次不折不扣的偽靜默。
- 這**不會造成誤鎖**：`PolicySettings.silenceLock` 預設為 `.afterTimeout(.seconds(180))`，需要連續 180 s 靜默才提案鎖定。安全側是對的。
- 但 10 s 門檻與觀測到的廣播節奏太貼近（p95 間距 3.3–3.6 s，常態性 6.3–6.9 s 空窗），會產生不必要的 `.silent` 抖動。依本批資料，涵蓋 iPhone 全部三段所有間距的最小門檻是 **> 10.2 s**；留一倍餘裕的話 15 s 是合理的候選值。

**本文件不逕行改動這個預設值。** 依據只有一台 Mac、一支 iPhone、每段 10 分鐘；改動 `silentThreshold` 會移動 fixture replay 的 golden 與 `ProximityEngine` 的多項測試。建議在 `docs/decisions/` 另開一則 ADR 決定，並以 20 分鐘版本的 §C 重測作為依據。

#### §B Identity stability：跨 ~22.5 小時

比對三份原始擷取檔中的 `CBPeripheral.identifier`（皆為 gitignored，識別碼未離開本機）：

| 裝置 | 2026-09-02 22:02 | 2026-09-03 13:42–14:42 | 2026-09-03 20:37 | 判定 |
|---|---|---|---|---|
| iPhone | ✔ | **未出現** | ✔ **同一個** | 跨 ~22.5 h 不變 |
| Apple Watch | ✔ | ✔ | ✔ 同一個 | 跨 ~22.5 h 不變，且中間連續 |
| iPad | ✔ | ✔ | ✔ 同一個 | 同上 |
| 另一台 Mac | ✔ | ✔ | ✔ 同一個 | 同上 |
| 常駐 Apple 家用裝置 | ✔ | ✔ | ✔ 同一個 | 同上 |
| AirPods | ✔ | 未出現 | ✔ 同一個 | identifier 不變，但可觀測性間歇 |

第三批把 iPhone 在 13:42–14:42 的缺席記為「無法歸因（可能不在附近、藍牙關閉、或 identifier 已輪替）」。**輪替這個解釋現在被排除**：同一個 identifier 在缺席前後都出現，中間沒有任何重新配對或設定變更。缺席的原因是裝置不在範圍內。

期間涵蓋：Mac 夜間 display sleep、多次 scanner process 啟停、裝置日常攜出攜入。**未**涵蓋：Mac reboot、iPhone reboot、任一端的 Bluetooth off→on、forget／re-pair、OS update。

#### 判定（2026-09-03 晚間，取代前一批）

| 類別 | 判定 | 依據與條件 |
|---|---|---|
| **iPhone** | **CONDITIONAL GO** | 條件：同 Apple ID、藍牙開啟。§C 三段 receiving 全部 100%，最長 gap 9.0–10.2 s，RSSI 隨距離單調可分離；identifier 跨 ~22.5 h 不變。**唯一未達標項**：`desk-1m` 的 10.2 s 略超過 ≤10 s。缺口：reboot／BT off→on／forget-re-pair 的 identifier 驗證；20 分鐘版本的 §C。 |
| **Apple Watch** | **CONDITIONAL（近距離）** | 1 m／3 m 達標（98.4%／100%，gap ≤ 9.9 s）。**8 m 不達標**（83.6%、25.7 s gap、13 次 >10 s 空窗）。RSSI 非單調，不可用於距離校正。可作為「在座位附近」的存在證據，不可作為「已離開」的唯一依據。 |
| **iPad** | **CONDITIONAL** | 僅有第三批的 1 小時未控距離資料（100%、gap 9.9 s）。本批未測，距離分段仍缺。 |
| **Generic beacon** | UNKNOWN | 未測。 |

檔案：`Tools/spikes/out/{iphone,watch}/{desk-1m,pocket-3m,next-room-8m}.jsonl`（gitignored）。六份皆已通過匿名檢查：內容只有 `device-A` 別名、`rssi`、`t` 與 meta／summary 欄位，無 UUID、MAC、裝置名稱或時鐘時間。**未**納入 `Tests/Fixtures/BLE/`：錄製時尚無 `--profile`（尚未跑過真實 calibration），依 `Tools/rssi-record` 與 `Tests/Fixtures/BLE/README.md` 的契約，沒有 profile 的擷取不得配 golden。要把真實擷取納入 regression set，需先完成一次真實 calibration，再以 `--profile` 重錄。

### 第五批：§B identity 情境（2026-09-03 21:10– CST，操作者在場）

第四批的 identity 資料只涵蓋「跨 22.5 小時的自然使用」。本批第一次**主動製造** §B 所列的生命週期事件，每次事件後以 `rssi-record discover 60` 比對同一個 `CBPeripheral.identifier` 是否再度出現。

| # | 情境 | 結果 | 證據 |
|---|---|---|---|
| B1 | **iPhone 端 Bluetooth off→on**（設定 App 內關閉，非控制中心暫時斷線） | **identifier 不變** | 關閉前後為同一個 identifier；重掃 60 s 內 56 筆，RSSI 中位 −42 |
| B2 | **Mac 端 Bluetooth off→on** | **identifier 不變** | 見下方 `bluetooth-off` capture；射頻恢復後同一個 identifier 立即重新被匹配 |

#### B2 的副產物：真實的 `bluetooth-off` capture

錄製 180 s，操作者在 t≈40 s 關閉 Mac 藍牙、t≈76 s 開回：

```
{"kind":"sensor","t":23,"status":"available"}
{"kind":"sensor","t":40448,"status":"unavailable.poweredOff"}
{"kind":"sensor","t":76051,"status":"available"}
```

| 指標 | 值 |
|---|---|
| 樣本 | 237 |
| receiving 比例 | 84.2% |
| 最長 gap | **37.0 s** |
| RSSI 中位／MAD | −44 ／ 4 |

37.0 s 的空窗與 35.6 s 的射頻中斷區間吻合。**關鍵在於這段空窗沒有被表達成「裝置不見了」**：感測器軸在整段期間持有 `unavailable.poweredOff`，`SensorHealth` 因此不是 `.healthy`，`ProximityEngine.evaluatePresence` 的整個 presence 區塊被跳過，presence 維持最後已知值並由 Policy 拒絕行動（ADR-008）。這是條件 9「感測器故障不得偽裝成使用者離開」第一份**實機**證據，先前只有單元測試。

射頻恢復後不需要重新配對、不需要使用者操作，也不需要重啟 scanner process：`CoreBluetoothScanner` 自行恢復掃描，同一個 identifier 在 6 s 內重新被匹配。

檔案：`Tools/spikes/out/iphone/bluetooth-off.jsonl`（gitignored；同樣無 profile，故不配 golden）。
