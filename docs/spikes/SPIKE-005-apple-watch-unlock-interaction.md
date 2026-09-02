# SPIKE-005 Apple Watch Unlock Interaction
Status: NOT RUN　Priority: 3（MVP 4 前）

## Question
本 App 以 assertion 點亮螢幕後，macOS 的 Apple Watch 自動解鎖是否照常觸發？我們的 BLE 掃描是否干擾 Watch 解鎖的藍牙流程？Watch 解鎖後 `ScreenState` 的通知序列為何？

## Why it matters
主線承諾「Watch 使用者零動作解鎖」；若掃描干擾或點亮方式不觸發 Watch 流程，承諾不成立。

## Experiment
Watch 解鎖開啟；情境：手動按鍵點亮 vs 本 App 點亮，各 30 次；掃描開／關各半；記錄 Watch 解鎖成功率、延遲、SPIKE-001 工具的狀態序列。

## Success criteria
GO：本 App 點亮時 Watch 解鎖成功率與手動點亮無顯著差異（±5%），掃描不影響。
CONDITIONAL GO：需在點亮後暫停掃描 N 秒。
NO-GO：本 App 點亮時 Watch 解鎖不觸發 → 產品語意改為「螢幕已亮，請抬腕／碰 Touch ID」。

## Decision resulting from outcome
`WakeController` 後是否暫停掃描；README 用語。
