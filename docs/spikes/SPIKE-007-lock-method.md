# SPIKE-007 Lock Method
Status: NOT RUN　Priority: 2（MVP 3 前）

## Question
四條鎖定路徑各自的可靠度、延遲、權限需求與副作用：① displaySleep（IOKit `IORequestIdle`）+「睡眠後立即要求密碼」；② ⌃⌘Q via `CGEvent`（需 Accessibility）；③ `shortcuts run "Lock Screen"`（未文件化）；④ 啟動 `ScreenSaverEngine`。

## Why it matters
主線不要求 Accessibility，預設路徑必須是 ①③④ 之一；使用者的系統設定（要求密碼延遲）會影響 ①④ 是否真的「鎖」。

## Experiment
每條路徑 50 次：記錄從呼叫到 `ScreenState == .locked`（以 SPIKE-001 工具量測）的延遲、失敗次數、是否需權限、對外接螢幕／多螢幕的行為、對正在播放的媒體的影響。「要求密碼」設為立即／5 秒／關閉三種。

## Environment matrix
Required：Apple Silicon × macOS 26。Before v1：macOS 14／15、Intel、外接螢幕。

## Success criteria
GO：至少一條無權限路徑在「要求密碼＝立即」下 100% 鎖定且延遲 ≤ 2 s。
CONDITIONAL GO：需引導使用者設定「要求密碼」。
NO-GO：無權限路徑皆不可靠 → 主線需 Accessibility（產品決策）。

## Decision resulting from outcome
`MacOSLockController` 的策略順序與退回；onboarding 是否需檢查「要求密碼」設定。
