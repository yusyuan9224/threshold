# SPIKE-003 Wake Behavior
Status: NOT RUN　Priority: 3（MVP 4 前）　最後檢視：2026-09-02

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

**本 spike 沒有執行任何實驗，Status 維持 NOT RUN。**

`Tools/spikes/wake-display`（呼叫 `IOPMAssertionDeclareUserActivity`）已寫好但**沒有留下任何輸出檔**；`Tools/spikes/out/` 內只有 `ble-observe` 與 `screen-state` 的資料。

唯一相關的旁證來自 SPIKE-001／007 的 screen-run2：顯示器在 t = 4 766 ms 睡眠、t = 5 314 ms 醒來（548 ms 後）。**喚醒原因未記錄。**由於 `wake-display` 沒有輸出，無法宣稱是 assertion 造成的喚醒；使用者按鍵或觸控板同樣能解釋這次喚醒。此筆資料不計為本 spike 的證據。

### Not yet measured

本文件的四項實驗**全部未執行**：

1. 鎖定 → 等待 display sleep → 呼叫 assertion → 記錄是否點亮、延遲、登入畫面是否就緒、是否觸發 Watch 自動解鎖（50 次）
2. system sleep 下呼叫的結果
3. 持有 `PreventUserIdleSystemSleep` 60 min 的電池消耗與系統是否仍睡
4. Power Nap 文件與行為的查閱結論

`system-integration.md` §4 表格中與喚醒相關的每一列都維持「預期」，不改為「實測」。
