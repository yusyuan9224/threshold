# SPIKE-008 Input Idle Detection
Status: NOT RUN　Priority: 2（silence policy 前）

## Question
`CGEventSource.secondsSinceLastEventType(_:eventType:)` 用哪個 `stateID`（`.hidSystemState`／`.combinedSessionState`）、是否計入 synthetic event、在 lock screen／screen saver／display sleep／fast user switching 下回傳什麼、是否真的不需要 Accessibility？

## Why it matters
`inputIdle` 是 silence-based lock 的唯一 supporting evidence，也是 measuredFar 的誤鎖守衛；錯誤值會讓人在打字時被鎖，或讓 silence lock 永遠不觸發。

## Experiment
每 500 ms 輪詢兩種 stateID，記錄值；情境：正常打字／滑鼠、閒置 5 min、鎖定畫面下打字、screen saver、display sleep、fast user switching 後、以 `CGEvent` 送 synthetic 事件、未授權 Accessibility 的乾淨帳號。

## Success criteria
GO：存在一個 stateID 在所有情境下語意一致、免權限、不計 synthetic 事件。
CONDITIONAL GO：部分情境回傳無意義值但可辨識（provider 回 nil）。
NO-GO：需要 Accessibility 或值不可信 → silence lock 停用（`silenceLock = .never` 為預設）。

## Decision resulting from outcome
`MacOSInputActivityProvider` 的實作與 nil 條件；`PolicySettings.silenceLock` 預設值。
