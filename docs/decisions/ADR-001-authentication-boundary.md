# ADR-001 Product Authentication Boundary
Status: Accepted (2026-09-02)

## Context
BLEUnlock 與 ProximityLock 以「Keychain 取密碼 → CGEvent 打字」達成自動解鎖，結構上存在密碼打進錯誤視窗的競態（BLEUnlock #182）。macOS 沒有任何公開 API 可解鎖 loginwindow。

## Decision
主線模式 **Wake + Native Handoff**：App 不持有密碼、不模擬輸入、不執行 authentication；只負責 presence → lock／wake，authentication 交還 Touch ID／Apple Watch／密碼。
**Assisted Typed Unlock** 為研究性功能：Default OFF、額外 Accessibility、多步驟 opt-in、`UnlockSafetyGuard`、Fail Closed、必須通過 Security Validation Gate（0 unintended keystrokes）；MVP 6 才評估，不保證進 v1。先前藍圖將其列為 v1 免費功能——本 ADR 取代該決策。

## Alternatives
- 打字解鎖為主線：否決，結構性風險。
- 完全不提供打字解鎖：保留為 MVP 6 的可能結論。

## Consequences
主線 runtime graph 沒有任何需要 guard 的動作；`ThresholdSecurity` 為 reserved target。Mac mini／無 Touch ID 無 Watch 的使用者在主線只能得到「螢幕已亮、請輸入密碼」。
