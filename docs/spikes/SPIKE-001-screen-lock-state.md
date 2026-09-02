# SPIKE-001 Screen Lock State Detection
Status: NOT RUN　Priority: 2（MVP 3 前）

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
