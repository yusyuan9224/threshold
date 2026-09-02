# SPIKE-003 Wake Behavior
Status: PARTIAL（2026-09-02，display sleep 部分 3/3 成功；system sleep 未測）　Priority: 3（MVP 4 前）　最後檢視：2026-09-02

## Question
`IOPMAssertionDeclareUserActivity(_, kIOPMUserActiveLocal, &id)` 在「顯示器睡眠 + 已鎖定」下能否點亮螢幕並顯示登入畫面？是否需權限？system sleep 下是否有任何 supported 機制讓 App 喚醒 Mac？Dark Wake／Power Nap 是否相關？`PreventUserIdleSystemSleep` assertion 能否合理延長「醒著但螢幕暗」的時間？

## Why it matters
決定 Wake on Return 的產品語意邊界（display sleep vs system sleep）與是否提供「鎖定後保持清醒」opt-in。

## Experiment
1. 鎖定 → 等待 display sleep → 呼叫 assertion → 記錄是否點亮、延遲、登入畫面是否就緒、是否觸發 Watch 自動解鎖。50 次。
2. 進入 system sleep → 呼叫（若 process 仍執行）→ 記錄。
3. 持有 `PreventUserIdleSystemSleep` 60 min，記錄電池消耗（筆電）與系統是否仍進入睡眠。
4. 查閱 Power Nap 文件與行為，確認第三方 App 不被排程。

## Environment matrix
Required：Apple Silicon 筆電 × macOS 26（電池／插電）。Before v1：桌機、Intel、macOS 14／15。

## Success criteria
GO：display sleep 下 100% 點亮且免權限；system sleep 結論明確為「不可能」（記入產品語意）。
CONDITIONAL GO：需特定 assertion 型別或設定。
NO-GO：display sleep 下無法點亮 → Wake on Return 移除，主線只剩 Auto Lock。

## Decision resulting from outcome
`MacOSWakeController` 實作；`system-integration.md` §4 表格；是否開 post-MVP「保持清醒」選項。

## Evidence（2026-09-02）

### 第二批（2026-09-02 14:44–14:46 UTC，自動化執行）

環境：Apple Silicon Mac，macOS 26.6.2，接 AC 電源，system sleep 被 assertion 阻止（`pmset -g` 顯示 sleep prevented），螢幕已鎖定且「睡眠後立即要求密碼」，使用者閒置 > 11 分鐘（`ioreg` HIDIdleTime）。
流程（`Tools/spikes/screen-state` 記錄 + script 驅動，3 次迭代）：`pmset displaysleepnow` → 等 12 s → `Tools/spikes/wake-display`（`IOPMAssertionDeclareUserActivity(_, kIOPMUserActiveLocal, &id)`）→ 觀察 `CGDisplayIsAsleep`。

| 迭代 | assertion 回傳 | 呼叫前顯示器 | 呼叫後 `CGDisplayIsAsleep` 轉 false | 鎖定狀態 | `IsSecureEventInputEnabled` |
|---|---|---|---|---|---|
| 1 | `kIOReturnSuccess`（0） | asleep | ≈ +100 ms（t 15 111 ms，呼叫於 ≈ 15 000 ms） | 維持 locked | 點亮後 49 ms 內 enabled（登入視窗密碼欄就緒） |
| 2 | 0 | asleep | ≈ +150 ms（t 15 150 ms） | 維持 locked | 同上 |
| 3 | 0 | asleep | ≈ +150 ms（t 15 156 ms） | 維持 locked | 同上 |

- 3/3 點亮，延遲 ≤ 150 ms（含 script 排程誤差），未出現任何權限對話，process 為一般使用者權限的 CLI。
- 點亮後鎖定狀態不變（`CGSSessionScreenIsLocked == 1` 全程），登入畫面就緒可直接輸入密碼／Touch ID。
- 副作用：無人輸入時，登入畫面在點亮後約 **33 s** 再度熄滅（迭代 2、3 開始時顯示器為亮、於 t ≈ 220 ms 自行睡眠，距前一次點亮約 33 s）。Wake on Return 的「亮」是一個約 30 s 的視窗，不是持續狀態。
- 是否觸發 Apple Watch 自動解鎖：無 Watch 在旁，未觀察。

`Tools/spikes/out/spike003-run{1,2,3}.jsonl` 與 `spike003-cmds.jsonl`（gitignored）。

唯一相關的旁證來自 SPIKE-001／007 的 screen-run2：顯示器在 t = 4 766 ms 睡眠、t = 5 314 ms 醒來（548 ms 後）。**喚醒原因未記錄。**由於 `wake-display` 沒有輸出，無法宣稱是 assertion 造成的喚醒；使用者按鍵或觸控板同樣能解釋這次喚醒。此筆資料不計為本 spike 的證據。

### Not yet measured

1. 實驗 1：已有 3 次（規格 50 次）；Watch 自動解鎖互動未測。
2. system sleep 下呼叫的結果 —— **未測**（本機 system sleep 被阻止；且產品語意已定義為不可能，見 system-integration.md §4）
3. 持有 `PreventUserIdleSystemSleep` 60 min 的電池消耗與系統是否仍睡
4. Power Nap 文件與行為的查閱結論

### Preliminary reading
display sleep + locked 下 assertion 點亮：3/3、≤ 150 ms、免權限 → 朝 **GO** 方向；樣本數不足規格的 50 次，且 Watch 互動未測，故維持 PARTIAL。system sleep 部分依產品語意不主張（無 supported 機制），本文件不會為它產生 GO。
`system-integration.md` §4「Display asleep、system awake」列的 assertion 項改為實測；system sleep 列維持產品定義。
