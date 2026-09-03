# ADR-009 Supported Device Policy
Status: Accepted (2026-09-02)

## Context
「CoreBluetooth 掃描就能長期穩定觀察 iPhone／Apple Watch」是未經驗證的假設；BLEUnlock 以系統藍牙資料庫（需完全取用磁碟）與 Active 連線補強，兩者都不採用。

## Decision
**A device is supported only if its presence can be observed reliably through supported APIs.**
- SPIKE-009 為 MVP 1 前的 GO／NO-GO 閘門：每種裝置輸出 `SUPPORTED / CONDITIONAL / UNSUITABLE / UNKNOWN` 與 companion／service UUID／可靠度三欄。
- NO-GO 的後果：改 supported device 策略（例如 MVP 只支援明確廣播的 generic BLE 裝置，iPhone 留待 companion app），**不以 private API 或 undocumented 資料庫硬救**。
- 結果直接改寫 README、onboarding、supported list、行銷用語、DeviceRegistry、calibration、MVP 1 exit criteria。

## Consequences
產品宣稱受實驗約束；SPIKE-009 優先於任何 RSSI 優化。

## Evidence status 2026-09-02
SPIKE-009 為 **PARTIAL**，不是 GO、也不是 CONDITIONAL GO。本節摘錄該文件的 Evidence 表，供 README／onboarding／行銷文案引用；任何超出下表的宣稱都沒有依據。

### 已觀察到的（run2，600 s，單一 Apple Silicon Mac × macOS 26.6.2）

| 代號 | 推定類別 | 有樣本的 10 s 視窗 | RSSI 中位／最低 |
|---|---|---|---|
| A | iPhone（同 Apple ID） | 60/60（100%） | −46 ／ −65 |
| B | Apple Watch（同 Apple ID） | 60/60（100%） | −58 ／ −83 |
| C | iPad（同 Apple ID） | 60/60（100%） | −56 ／ −89 |
| D | 另一台 Mac（同 Apple ID） | 20/60（33%） | −59 ／ −85 |
| E | AirPods | 29/60（48%） | −63 ／ −81 |

以 `scanForPeripherals(withServices: nil, allowDuplicates: true)` 掃描，全程不需 companion app、不需事先知道 service UUID、不需連線。裝置類別由廣播名稱推定，未交叉驗證。裝置 D 出現一段 ≥ 120 s 的空窗。

**Identity stability**：只驗證了 scanner process restart 一項 —— 兩個相隔約 53 s 的獨立 process，11 個具名裝置的 `CBPeripheral.identifier` 全部相同（11/11）。這是 identifier 穩定性最弱的一種驗證。

**Not yet measured**：A 節的情境矩陣（距離／螢幕狀態／鎖定狀態／idle 時間）完全未跑；B 節的 Mac reboot、裝置 reboot、Bluetooth off→on（兩端）、forget／re-pair、24 小時 idle、OS update 全部未測；C 節的 1 m／3 m／8 m 距離矩陣與 1 小時連續觀察未測，最長 silent gap 只能得到 < 20 s 的上界，無法驗證成功條件的 ≤ 10 s；generic BLE beacon（iBeacon／AltBeacon）未測。環境矩陣只有一台 Apple Silicon Mac × macOS 26。

### 使用者可見文字的措辭規則

在上述矩陣補完前，README、onboarding、supported list、設定畫面與行銷文案對裝置一律寫「**已觀察到**」，不寫「**支援**」。ADR-009 的 Decision 說一個裝置只有在能被穩定觀察時才算 supported；目前沒有任何裝置滿足 SPIKE-009 的 SUPPORTED 條件，因此 supported list 尚不存在，只有觀察紀錄。`docs/release.md` §5 把這條列為發版前的文件檢查項。

### 補完矩陣的方式

缺的每一項都需要有人拿著裝置移動，無法自動化。工具與逐項 checklist 在 `Tools/rssi-record/README.md` 的 Field protocol 一節（§A 裝置發現矩陣、§B 身分穩定性、§C presence 適用性），成功條件為 1 m 與 3 m 下 `receivingRatio ≥ 0.95` 且 `longestGapMs ≤ 10000`。`rssi-record` 驅動 production 的 `CoreBluetoothScanner`，其 summary 行不含任何 identifier 或名稱，可直接引用回 SPIKE-009。
