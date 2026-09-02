# ADR-003 Proximity Engine Architecture
Status: Accepted (2026-09-02)

## Context
RSSI 不穩定；BLEUnlock 的 moving average + 固定 dBm 門檻造成誤鎖／誤解鎖，且引擎與 CoreBluetooth／系統 API 耦合而無法測試。

## Decision
1. **Domain owns temporal rules but never owns time.** 引擎完全輸入驅動（`observation`／`sensor`／`tick`／`reset`），時間以 `MonotonicInstant`（Int64 ns）隨輸入進來，引擎輸出 `nextDeadline` 讓外層排程；Domain 從不呼叫 clock，不存在 wall-clock 型別。
2. 三軸正交：`PresenceState`、`SensorHealth`、`DeviceObservationState`。
3. 管線：Validate → Window → Median → EMA → 三因子 `PresenceScore`（distance／recency／sufficiency）→ fusion（只計 receiving 裝置）→ 遲滯 + 持續時間 + 最小樣本 → transition。
4. Presence evidence provenance（`measuredNear`／`measuredFar`／`departureThenSilent`／`none`）隨 snapshot 保留。
5. Policy 為 snapshot 純函式 + action ledger；raw RSSI 永不直達 system action。
6. Calibration gate：無有效 profile 不 armed；`CalibrationProfile.default` 僅供顯示。
7. Persistence 只有 device identity、calibration、settings；runtime evidence 不跨 process。
8. Reset（wake／BT reset／session change／devices change）回 `unknown` 並重新累積證據。

## Alternatives
固定 dBm 門檻（否決）；ML（否決，不可解釋）；per-device 雙層狀態機（延後：fusion seam 已足夠）。

## Consequences
所有核心規則可 deterministic 測試；fixture replay 成為回歸基準；多裝置只需新增 fusion 策略。
