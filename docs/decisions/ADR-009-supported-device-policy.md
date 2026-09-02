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
