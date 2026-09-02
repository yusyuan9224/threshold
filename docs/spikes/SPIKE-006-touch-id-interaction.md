# SPIKE-006 Touch ID Interaction
Status: NOT RUN　Priority: 3（MVP 4 前）

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
