# SPIKE-001 Screen Lock State Detection
Status: PARTIAL — 2026-09-02　Priority: 2（MVP 3 前）

## Question
`com.apple.screenIsLocked`／`com.apple.screenIsUnlocked`（transition）與 `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`（state）是否可靠、延遲多少、兩者不一致持續多久？

## Why it matters
`ScreenState` 是 lock／wake 的 required precondition；`.unknown` 太久會讓自動保護長時間停擺，錯誤的 `.unlocked` 會造成重複 lock。「兩源一致才回報」是假說，需實驗決定 settling window 與 source confidence。

## Experiment
Throwaway 工具同時訂閱通知並每 50 ms 輪詢 query，記錄 (t, source, value)。情境：手動鎖定（⌃⌘Q）、密碼解鎖、Touch ID 解鎖、Apple Watch 解鎖、display sleep 後鎖定、system sleep／wake、screen saver 啟動／結束（含「立即要求密碼」開／關）、fast user switching、第二個使用者登入中。各 20 次。

## Environment matrix
Required：Apple Silicon × macOS 26 × Password + Touch ID。Before v1：Apple Watch、macOS 14／15、Intel、多使用者。

## Expected evidence
每情境：通知到達時間、query 翻轉時間、mismatch 持續時間分佈、false positive／negative 次數。

## Success criteria
GO：兩源在 ≤ 500 ms 內收斂，0 false positive；可定義 settling window。
CONDITIONAL GO：特定情境（如 screen saver）需額外訊號。
NO-GO：任一情境出現持續性 false `.unlocked`。

## Decision resulting from outcome
寫入 `MacOSScreenStateProvider` 的合成規則（settling window、source confidence）；NO-GO 時 lock 規則改為只依賴 `.locked` 通知的保守版本。

## Evidence（2026-09-02）

### 環境
Apple Silicon（arm64）Mac，macOS 26.6.2（build 25G83；由事後 `sw_vers` 取得，工具未記錄版本）。單一使用者、單一 session，`kCGSessionOnConsoleKey` 全程為 1。

### 工具與回合
Throwaway CLI `Tools/spikes/screen-state`：同時訂閱 6 個 distributed notification 與 6 個 `NSWorkspace` 通知，並以 **50 ms** 週期輪詢 `CGSessionCopyCurrentDictionary()`，只在值變化時輸出。

| 回合 | 長度 | 情境 |
|---|---|---|
| screen-run1 | 120 s | 手動鎖定 → 解鎖 |
| screen-run2 | 75 s | 顯示器睡眠導致的鎖定 → 喚醒 → 解鎖 |

解鎖方式（密碼／Touch ID／Apple Watch）**工具未記錄**。

### 兩源時序（全部 4 個事件）

| 事件 | query 翻轉 t | 通知抵達 t | 通知落後 query | 通知抵達當下的 query 值 |
|---|---|---|---|---|
| run1 手動鎖定 | 4 819 ms | 4 926 ms | **107 ms** | `1`（與通知一致） |
| run1 解鎖 | 9 525 ms | 9 532 ms | **7 ms** | 鍵不存在（與通知一致） |
| run2 顯示器睡眠後鎖定 | 4 842 ms | 4 922 ms | **80 ms** | `1`（與通知一致） |
| run2 解鎖 | 7 456 ms | 7 496 ms | **40 ms** | 鍵不存在（與通知一致） |

- 4/4 事件中通知**都晚於** query，落後 7–107 ms，全部遠低於成功條件的 500 ms。
- 輪詢週期 50 ms，故 query 翻轉時刻帶有最多 50 ms 的量化誤差；真實落後量約在 0–110 ms 區間。
- mismatch 次數 **0**：通知抵達當下 query 的值一律與通知語意相符，未觀察到需要 settling window 才能消解的不一致。
- false `.unlocked` **0** 次；false `.locked` **0** 次。

### 關鍵發現：解鎖時 `CGSSessionScreenIsLocked` 這個鍵不存在

`CGSessionCopyCurrentDictionary()` 回傳的 dictionary 在**鎖定時**含有 `CGSSessionScreenIsLocked = 1`，在**未鎖定時完全不含這個鍵**（工具以 `-1` 表示「取不到」）。四個事件與兩回合起始狀態一致呈現這個行為。

對 `MacOSScreenStateProvider` 的直接後果：**「讀不到鍵」必須解讀為 unlocked，不能解讀為 `.unknown`**。若把缺鍵當成 `.unknown`，provider 在正常未鎖狀態下會永久卡在 `.unknown`，自動保護將完全不會啟動。

### 其他觀察

- `kCGSessionOnConsoleKey` 在鎖定與解鎖期間都維持 `1`，不隨螢幕鎖定改變，因此**不能**用它判斷鎖定。
- `IsSecureEventInputEnabled()`：run1 全程 `false`；run2 在 t = 5 378 ms 轉 `true`、t = 5 478 ms 轉回 `false`（僅 100 ms），發生在解鎖前約 2 s。單一樣本、成因不明，不足以推論任何規則。
- 兩回合都沒有觸發 `com.apple.screensaver.didstart`／`didstop` 或任何 `NSWorkspace` sleep／wake 通知。

### Not yet measured

對應本文件的實驗章節：

- **樣本數**：規格要求每情境 20 次，實際為鎖定 2 次、解鎖 2 次，總觀測時間 195 s。
- **情境**：⌃⌘Q 手動鎖定（run1 的鎖定觸發方式未記錄）、**密碼解鎖／Touch ID 解鎖／Apple Watch 解鎖三者未分別記錄**、system sleep／wake、screen saver 啟動與結束（含「立即要求密碼」開／關兩組）、fast user switching、第二個使用者登入中 —— 皆未測。
- **mismatch 持續時間分佈**：只有 4 個樣本且全部為 0 mismatch，無法構成分佈。
- **環境矩陣**：只有一台 Apple Silicon Mac × macOS 26。macOS 14／15、Intel、多使用者未測。

### Preliminary reading

尚無 GO/NO-GO：成功條件要求「各情境 20 次」，目前每情境 1–2 次。

目前資料**不反對**現行假說，並提供兩點可以直接寫進實作的約束：

1. 在已測到的 4 個事件中，兩源在 ≤ 110 ms 內收斂、0 mismatch、0 false positive。`system-integration.md` §1 假設的 500 ms settling window 與這批資料**相容**，且看起來有相當餘裕；但 4 個樣本不足以決定 window 大小，也還沒碰到最可能出問題的情境（screen saver、fast user switching）。
2. 「鍵不存在 = 未鎖定」是必須實作的解讀方式，這一點資料明確，不需要更多樣本。

在補完 screen saver 與 fast user switching 之前，不應把「兩源一致才回報」從假說升級為 production contract。
