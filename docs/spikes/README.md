# Spikes

每個 Spike 回答一個高風險 unknown。**未執行前不寫結果**；`Status: NOT RUN` 直到有實驗紀錄。有量測但成功條件未完整驗證時為 `PARTIAL`。最終結果只能是 `GO / CONDITIONAL GO / NO-GO`，附證據。

| ID | 問題 | 阻擋 | 順序 | Status |
|---|---|---|---|---|
| SPIKE-009 | 我們宣稱支援的裝置能否被穩定觀察 | MVP 1A | **1** | PARTIAL（2026-09-02） |
| SPIKE-004 | CoreBluetooth 生命週期 | MVP 1A | 1（同批） | PARTIAL（2026-09-02） |
| SPIKE-001 | 鎖定狀態偵測 | MVP 3 | 2（MVP 2 期間） | PARTIAL（2026-09-02） |
| SPIKE-007 | 鎖定方法 | MVP 3 | 2 | PARTIAL（2026-09-02） |
| SPIKE-008 | 輸入閒置偵測 | MVP 3（silence policy） | 2 | CONDITIONAL GO（2026-09-02；`.hidSystemState`，鎖定時 nil） |
| SPIKE-003 | 喚醒行為與 system sleep 邊界 | MVP 4 | 3（MVP 3 期間） | PARTIAL（2026-09-02，display sleep 3/3） |
| SPIKE-005 | Apple Watch 解鎖互動 | MVP 4 | 3 | NOT RUN |
| SPIKE-006 | Touch ID 互動 | MVP 4 | 3 | NOT RUN |
| SPIKE-002 | loginwindow 偵測 | MVP 6 | 4（MVP 5 後） | NOT RUN |

Spike 產出的程式碼一律標記 throwaway，放在 `Tools/spikes/<id>/`，不進 production target。

**PARTIAL 的意思**：有實際量測紀錄，但成功條件未被完整驗證，因此**沒有** GO／CONDITIONAL GO／NO-GO 結論。每份 PARTIAL 文件內都有 `## Evidence` 與一份明確的「Not yet measured」清單。

原始量測資料在 `Tools/spikes/out/`（JSONL），**已列入 `.gitignore` 不進版控**：內容含 `CBPeripheral.identifier`、裝置廣播名稱等可識別資訊。文件中一律以「裝置 A／B／…」代稱，不寫入任何 identifier、裝置名稱或主機名稱。

2026-09-02 的實測工具：`Tools/spikes/ble-observe`（SPIKE-009／004）、`Tools/spikes/screen-state`（SPIKE-001／007，以及 SPIKE-008 的無效嘗試）、`Tools/spikes/wake-display`（SPIKE-003，3 次）。工具目錄命名與上述 `<id>` 慣例不同。

`screen-state` 的 idle 探針傳入 `CGEventType.null` 而非 `kCGAnyInputEventType`，SPIKE-008 的資料因此無效；重測前需先修正該工具。

## 實機矩陣分級
- **Required for MVP**：Apple Silicon × macOS 26 × iPhone × {Password, Touch ID} × {awake, screen locked, display sleep, system sleep}
- **Required before v1**：+ macOS 14／15、Apple Watch、Intel、screen saver、fast user switching
- **Nice to have**：generic beacon 多品牌、多使用者帳號、AirPods（觀察）
