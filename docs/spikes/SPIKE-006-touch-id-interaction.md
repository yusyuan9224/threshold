# SPIKE-006 Touch ID Interaction
Status: GO（內建鍵盤，n=5）— 2026-09-03；樣本數與外接鍵盤未達規格　Priority: 3（MVP 4 前）

## Question
本 App 點亮螢幕後，Touch ID 感測器是否立即就緒（碰一下即解鎖）？是否需要先按鍵？外接 Touch ID 鍵盤（Mac mini）行為是否相同？

## Why it matters
「碰一下」是主線對 Touch ID 使用者的承諾。

## Experiment
點亮後立即碰 Touch ID，30 次；記錄成功率與是否需額外按鍵。內建與外接鍵盤各測。

## Success criteria
GO：≥ 95% 一碰即解鎖。CONDITIONAL GO：需先任意按鍵（onboarding 說明）。NO-GO：無法解鎖（極不可能）。

## Decision resulting from outcome
Onboarding 文案；README。

## Evidence（2026-09-03 21:39 CST）

### 環境
同 SPIKE-005；MacBook Pro（`Mac17,2`，Apple M5），內建 Touch ID，`bioutil -r` 確認「Biometrics for unlock: 1」。觸發同樣是 `pmset displaysleepnow`；每次鎖定後立即碰內建 Touch ID，不先按任何鍵。

### 結果：5/5 成功，0 失敗，全部一碰即解鎖

| trial | displaySleep→locked | displayWake→unlocked | locked→unlocked 總長 |
|---|---|---|---|
| 1 | 92 ms | **624 ms** | 3 174 ms |
| 2 | 85 ms | **485 ms** | 2 966 ms |
| 3 | 84 ms | **370 ms** | 2 350 ms |
| 4 | 77 ms | **434 ms** | 2 465 ms |
| 5 | 62 ms | **398 ms** | 2 513 ms |

`displayWake→unlocked` 全部在 650 ms 內，比同一場景測得的 Apple Watch 解鎖（1.7–2.8 s）快 3–5 倍且離散度小得多（Touch ID 的 5 個值落在 370–624 ms，Watch 的 9 個值落在 1 696–2 821 ms）。5 次全部**一碰即解鎖**，沒有一次需要先按鍵或二次嘗試。外接 Touch ID 鍵盤（Mac mini 情境）未測——本機是 MacBook Pro 內建感測器。

### 判定：GO（內建 Touch ID；外接鍵盤未測）

依成功條件「≥ 95% 一碰即解鎖」：5/5 = 100%，達標，但樣本數（5）遠低於規格的 30 次。判定為條件性 GO：內建 Touch ID 的行為明確（快、穩、不需按鍵），外接鍵盤這個變因完全沒有證據。

### Not yet measured
- 樣本數（5 / 30）
- 外接 Touch ID 鍵盤（Mac mini 情境）
- 「要求密碼」5 秒／關閉兩組設定

檔案：`Tools/spikes/out/screen-run-unlock.jsonl`（同 SPIKE-005，同一份錄製涵蓋兩者）。
