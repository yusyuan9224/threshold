# ADR-004 Public / Private API Policy
Status: Accepted (2026-09-02)

## Context
BLEUnlock 依賴 `login.framework`、`MediaRemote`（macOS 15.4 起被 entitlement 封鎖）、`NSUserNotification`、`/Library/Bluetooth` 資料庫（macOS 26 需完全取用磁碟）。

## Decision
- 只使用 Apple 公開且受支援的 API 作為 production 路徑。
- 未文件化但長期穩定的訊號（`com.apple.screenIsLocked`、`CGSSessionScreenIsLocked`、`shortcuts run`）只能出現在 `ThresholdSystem` 的 provider／controller 內，必須有 Fake 與 Spike 驗證，失效時只替換該實作。
- 禁止 private framework、禁止讀系統藍牙資料庫、禁止 IOBluetooth（MVP 無需求；未來若需要另開 ADR）。
- 暫停播放等只能靠 private API 的功能：不做或降級為選用 best-effort。

## Consequences
裝置名稱由使用者命名；部分「方便」功能放棄；每年 beta 相容性 CI 為固定成本。
