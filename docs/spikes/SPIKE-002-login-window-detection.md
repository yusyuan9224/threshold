# SPIKE-002 Login Window Detection
Status: NOT RUN　Priority: 4（MVP 6；只服務 Assisted Typed Unlock）

## Question
能否可靠確認「現在 keyboard input 的目的地真的是 macOS authentication UI」？候選訊號：`CGWindowListCopyWindowInfo`（loginwindow 擁有最上層視窗）、視窗擁有者 process、`IsSecureEventInputEnabled()`（只是一個 signal，不是 loginwindow 的證明）、session state。

## Why it matters
這是 Assisted Typed Unlock 存廢的決定點。BLEUnlock #182 的根因正是缺這一層。

## Experiment
在以下情境記錄四個訊號的值與時序：鎖定畫面密碼欄取得焦點、鎖定畫面剛出現尚未取得焦點、Safari 密碼欄、Terminal（secure input）、1Password 等啟用 secure input 的 App、Touch ID 解鎖瞬間、Watch 解鎖瞬間、wake 後 0–2 s。各 30 次。

## Success criteria
GO：存在訊號組合在「鎖定畫面密碼欄」為 100% 真、在其他所有情境為 100% 假，且時序上在解鎖瞬間前翻轉。
NO-GO：任何 false positive → Assisted Typed Unlock 不進產品（記 ADR）。

## Decision resulting from outcome
`ThresholdSecurity` 是否建立；`LoginWindowProviding` 的實作或功能刪除。
