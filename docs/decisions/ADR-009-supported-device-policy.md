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

## Evidence status 2026-09-03（第三批）
1 h presence-suitability（`Tools/rssi-record`，production scanner）與 19 h identity 觀察（見 SPIKE-009 第三批）：

| 類別 | 判定 | 使用者文案 |
|---|---|---|
| Apple Watch（同 Apple ID） | CONDITIONAL：1 h receiving 100%、最長 gap 6.9 s、identifier 跨 19 h 不變；距離分段與 reboot／BT 切換未測 | 「已在座位附近驗證；離開距離的行為仍在驗證中」 |
| iPad（同 Apple ID） | CONDITIONAL：1 h receiving 100%、最長 gap 9.9 s、identifier 跨 19 h 不變 | 同上 |
| iPhone | UNKNOWN：前日 600 s 連續可觀察，但跨日 identifier 未再出現、1 h 資料缺 | 不列入；onboarding 顯示「已觀察到」而非「支援」 |
| Generic beacon | UNKNOWN | 不列入 |

**Supported-device list（evidence-based，2026-09-03）**：Apple Watch（conditional）、iPad（conditional）。iPhone 暫不列入，直到 SPIKE-009 §B（跨日／reboot）與 §C 對 iPhone 完成。

## Evidence status 2026-09-03 晚間（第四批，取代上表）

受控距離分段（每段 600 s；iPhone 全程鎖定螢幕熄滅、Apple Watch 全程配戴；見 SPIKE-009「第四批」）：

| 類別 | 判定 | 使用者文案 |
|---|---|---|
| iPhone（同 Apple ID） | **CONDITIONAL GO**：1 m／3 m／8 m receiving 皆 100%，最長 gap 10.2／9.9／9.0 s，RSSI 中位 −50／−60／−68 單調可分離；identifier 跨 ~22.5 h 不變 | 「已驗證：桌上、口袋、隔壁房間皆可穩定觀察」 |
| Apple Watch（同 Apple ID） | **CONDITIONAL（僅近距離）**：1 m 98.4%、3 m 100%；**8 m 83.6%、最長 gap 25.7 s，不達標**；RSSI 非單調，不可用於距離校正 | 「已在座位附近驗證；離開距離會失去觀測，不可作為唯一 trusted device」 |
| iPad（同 Apple ID） | CONDITIONAL：1 h 未控距離 receiving 100%、gap 9.9 s；identifier 跨 ~22.5 h 不變；距離分段未測 | 「已在座位附近驗證；離開距離的行為仍在驗證中」 |
| Generic beacon | UNKNOWN | 不列入 |

**Supported-device list（evidence-based，2026-09-03 晚間）**：iPhone（conditional go，首選）、Apple Watch（conditional，僅近距離）、iPad（conditional）。

這修正了同日下午的判定方向。當時把 iPhone 記為 UNKNOWN 的唯一理由，是它的 identifier 在一段 1 小時觀察中未出現；比對三份原始擷取後確認**該 identifier 在缺席前後都相同**，缺席原因是裝置不在範圍內，不是 identifier 輪替。

決策影響：
1. iPhone 進入 supported list，且是唯一在「離開距離」仍可靠的類別 —— 離開判定（`departureThenSilent` 與 measuredFar 兩條路徑）應以 iPhone 為主要證據來源。
2. Apple Watch 不得作為唯一 trusted device：它在離開距離的失去觀測會被 `SensorHealth` 與 `PresenceEvidence` 正確地表達為「證據不足」（ADR-008），不會誤判為離開，但也因此無法完成離開判定。onboarding 需說明這一點。
3. calibration 的 near／far baseline 對 iPhone 有意義，對 Apple Watch 不成立（RSSI 非單調）。
