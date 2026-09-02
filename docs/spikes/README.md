# Spikes

每個 Spike 回答一個高風險 unknown。**未執行前不寫結果**；`Status: NOT RUN` 直到有實驗紀錄。結果只能是 `GO / CONDITIONAL GO / NO-GO`，附證據。

| ID | 問題 | 阻擋 | 順序 | Status |
|---|---|---|---|---|
| SPIKE-009 | 我們宣稱支援的裝置能否被穩定觀察 | MVP 1A | **1** | NOT RUN |
| SPIKE-004 | CoreBluetooth 生命週期 | MVP 1A | 1（同批） | NOT RUN |
| SPIKE-001 | 鎖定狀態偵測 | MVP 3 | 2（MVP 2 期間） | NOT RUN |
| SPIKE-007 | 鎖定方法 | MVP 3 | 2 | NOT RUN |
| SPIKE-008 | 輸入閒置偵測 | MVP 3（silence policy） | 2 | NOT RUN |
| SPIKE-003 | 喚醒行為與 system sleep 邊界 | MVP 4 | 3（MVP 3 期間） | NOT RUN |
| SPIKE-005 | Apple Watch 解鎖互動 | MVP 4 | 3 | NOT RUN |
| SPIKE-006 | Touch ID 互動 | MVP 4 | 3 | NOT RUN |
| SPIKE-002 | loginwindow 偵測 | MVP 6 | 4（MVP 5 後） | NOT RUN |

Spike 產出的程式碼一律標記 throwaway，放在 `Tools/spikes/<id>/`，不進 production target。

## 實機矩陣分級
- **Required for MVP**：Apple Silicon × macOS 26 × iPhone × {Password, Touch ID} × {awake, screen locked, display sleep, system sleep}
- **Required before v1**：+ macOS 14／15、Apple Watch、Intel、screen saver、fast user switching
- **Nice to have**：generic beacon 多品牌、多使用者帳號、AirPods（觀察）
