# ADR-007 Diagnostics / Privacy Model
Status: Accepted (2026-09-02)

## Context
使用者需要能回答「為什麼剛才鎖了？」；同時這是安全產品，預設不得外送資料。

## Decision
- 預設：本機處理、無雲端、無帳號、無 telemetry。Crash reporting／analytics 若未來加入必須 opt-in 且明確揭露；MVP 不依賴 cloud。
- `ThresholdDiagnostics` 為獨立葉 target，**只有 App 依賴它**；Domain 以回傳值輸出 transition／decision／rationale，`DiagnosticsRecorder`（actor）在 App 層訂閱 Coordinator 事件轉成 `DiagnosticEvent`。Domain 可在完全不知道 diagnostics 存在的情況下執行。
- 記錄：BLE samples、filtered signal、presence confidence、state transitions（三軸）、policy decisions 與 rationale、lock／wake requests 與 outcome（含 stale）、system lifecycle、Bluetooth lifecycle、security guard denial reason（未來）。
- 禁止：密碼、任何憑證、完整 identifier／MAC（以穩定短雜湊代替）、裝置名稱以外的裝置資料。
- 環形緩衝 10,000 筆；匯出為去識別化 JSON；wall-clock 只在 App 層附加。

## Consequences
UI 以 1 Hz 拉 `DiagnosticsSnapshot`；issue report 附匯出檔即可重建事件序列。
