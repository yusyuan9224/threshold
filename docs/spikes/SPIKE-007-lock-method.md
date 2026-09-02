# SPIKE-007 Lock Method
Status: PARTIAL — 2026-09-02　Priority: 2（MVP 3 前）

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

## Evidence（2026-09-02）

### 環境
Apple Silicon（arm64）Mac，macOS 26.6.2（build 25G83；由事後 `sw_vers` 取得，工具未記錄版本）。系統「睡眠後要求密碼」設為**立即**。單一內建顯示器，未接外接螢幕。無媒體播放。

### 工具與回合
`Tools/spikes/screen-state`（同 SPIKE-001），75 s 的 screen-run2。以 `CGDisplayIsAsleep(CGMainDisplayID())` 每 50 ms 輪詢顯示器狀態，並同步記錄 lock query 與通知。

**觸發方式的重要限制**：這次的顯示器睡眠是以 `pmset displaysleepnow` 觸發（依執行者記錄；工具本身沒有記錄觸發方式），**不是**本文件路徑 ① 所指的 IOKit `IORequestIdle`。兩者是否等價未經驗證。

### 路徑 ① 的單一樣本（n = 1）

| 事件 | t | 相對於顯示器睡眠 |
|---|---|---|
| `CGDisplayIsAsleep` 轉 true | 4 766 ms | 0 |
| `CGSSessionScreenIsLocked` 轉 `1` | 4 842 ms | **+76 ms** |
| `com.apple.screenIsLocked` 通知抵達 | 4 922 ms | **+156 ms** |
| `CGDisplayIsAsleep` 轉回 false | 5 314 ms | +548 ms |

從顯示器睡眠到 `ScreenState == .locked` 約 76–156 ms（取 query 或通知為準），遠低於成功條件的 2 s。失敗 0 次（樣本 1 次）。全程未出現任何權限對話。

顯示器在 548 ms 後就醒了，喚醒原因未記錄（見 SPIKE-003）。

### Not yet measured

對應本文件的實驗章節：

- **樣本數**：規格要求每條路徑 50 次；路徑 ① 實際 1 次。
- **路徑 ②（⌃⌘Q via `CGEvent`）、③（`shortcuts run "Lock Screen"`）、④（`ScreenSaverEngine`）**：完全未測。
- **路徑 ① 的規格實作**：IOKit `IORequestIdle` 未測，本次以 `pmset displaysleepnow` 代替。
- **「要求密碼」設定**：只測了「立即」。5 秒、關閉兩組未測 —— 這正是判斷路徑 ①④ 是否真的「鎖」的關鍵變因。
- 外接螢幕／多螢幕行為、對播放中媒體的影響、權限需求的正式確認 —— 未測。
- macOS 14／15、Intel 未測。

### Preliminary reading

尚無 GO/NO-GO。成功條件要求「至少一條無權限路徑在『要求密碼＝立即』下 **100% 鎖定**（50 次）且延遲 ≤ 2 s」，目前只有 1 次成功樣本。

這 1 次樣本顯示：在「要求密碼＝立即」下，顯示器睡眠**確實**在 156 ms 內帶出 `com.apple.screenIsLocked`，且不需要任何權限。這是路徑 ① 值得優先投資的初步理由，但不足以定下 `MacOSLockController` 的策略順序與退回邏輯。下一步應先補齊路徑 ① 的 50 次重複與「要求密碼」的三種設定，再測 ③④。
