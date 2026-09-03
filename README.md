# Threshold

> A security-first macOS proximity application that automatically protects the Mac when the user leaves and prepares it for secure native authentication when the user returns.

工作代號 **Threshold**（正式命名前需做商標檢索）。

## 現況（2026-09-02）

Domain／Bluetooth／System／Diagnostics／Runtime／App 六層皆已實作，`swift test` 全綠，App 可組成 `Threshold.app` 執行。**尚未達到 v1.0**：兩項阻擋皆在 repo 之外。

| 項目 | 狀態 |
|---|---|
| 實作 | 完成（Domain、Bluetooth、System、Diagnostics、Runtime、AppKit／App） |
| 自動化驗證 | `check-boundaries.sh` + `swift build` + `swift test` + bundle，CI 每個 PR 跑同一組 |
| 實機驗證 | **未完成** —— SPIKE-009 的距離／鎖定／reboot 矩陣需要有人拿著裝置移動，見下方 spike 表 |
| 簽章與 notarization | **EXTERNAL BLOCKER** —— repo 內無憑證，`docs/release.md` §4 已寫好步驟但從未執行 |

## App 做什麼

```text
Presence Detection → Automatic Protection → Native Authentication Handoff
```

App **不持有登入密碼、不模擬輸入密碼、不執行 authentication**；authentication 交還給 macOS（Touch ID／Apple Watch／密碼）。

| 功能 | 機制 | 邊界 |
|---|---|---|
| **Auto Lock** | 判定使用者離開後，經由 display-sleep 路徑要求鎖定（IOKit `IODisplayWrangler` 的 `IORequestIdle`，退回 `pmset displaysleepnow`），再**向 `ScreenStateProviding` 確認結果**才算成功 | 使用者若未設「睡眠後立即要求密碼」，顯示器會睡但不會鎖 —— 這正是需要確認而非信任的原因 |
| **Wake on Return** | 使用者回來時呼叫 `IOPMAssertionDeclareUserActivity` 點亮顯示器，交還登入畫面 | **只在 Mac 醒著、顯示器睡眠或已鎖定時有效。不宣稱能把 Mac 從 system sleep 喚醒** —— 第三方 App 沒有 supported 機制做到（`docs/specs/system-integration.md` §4）。SPIKE-003 實測 display sleep + locked 下 3/3 於 ≤ 150 ms 點亮、免權限、鎖定不變；點亮後無輸入約 33 s 會再度熄滅 |
| **Diagnostics** | 環形緩衝記錄 transition／decision／rationale，UI 可回答「為什麼剛才鎖了？」，匯出為去識別化 JSON | 匯出前過濾敏感樣式，未通過就不寫檔（fail-closed） |

Mac 進入完全睡眠後，使用者第一次按鍵／觸碰觸控板喚醒它，之後 Touch ID／Apple Watch 照常接手（SPIKE-006：內建 Touch ID 一碰即解鎖，5/5，延遲 370–624 ms；SPIKE-005：Apple Watch 9/9，含本 App 掃描同時進行的 2 次，掃描未觀察到干擾）。

## 三條原則（見 docs/decisions）

1. Domain owns temporal rules but never owns time.（ADR-003）
2. Absence of evidence is not evidence of absence.（ADR-008）
3. A device is supported only if its presence can be observed reliably through supported APIs.（ADR-009）

## 隱私（ADR-007）

- 預設**本機處理、無雲端、無帳號、無 telemetry**。MVP 不依賴任何雲端服務。
- 診斷紀錄禁止寫入密碼、任何憑證、完整 identifier／MAC（以 process 內穩定別名 `device-N` 代替，別名表不匯出）。
- 匯出檔去識別化，並在寫出前跑一次匿名性檢查。
- 測試 fixtures 同規則：`scripts/check-boundaries.sh` 會擋下含 UUID 或 MAC 的 fixture；廣播名稱與 wall-clock 由 `rssi-record` 在寫檔時就不產生。

## 建置、測試、打包

```bash
scripts/check-boundaries.sh                  # 架構與隱私邊界
swift build
swift test
scripts/make-app-bundle.sh release           # → build/Threshold.app
swift build --package-path Tools/rssi-record
```

需求：macOS 14.0 以上（deployment target）、Swift 6 language mode。開發與 CI 都不需要 Xcode 專案，App 是 SwiftPM executable（ADR-011）。`make-app-bundle.sh` 產出的 bundle **未簽章**，不可作為散布產物；散布流程見 `docs/release.md`。

| Target | 內容 |
|---|---|
| `ThresholdDomain` | 純邏輯：observation 驗證、訊號管線、presence 評分、三軸狀態機、Policy、ledger、calibration。只依賴 stdlib |
| `ThresholdBluetooth` | CoreBluetooth adapter、三通道 stream、`DeviceRegistry`、Fake |
| `ThresholdSystem` | macOS providers／controllers／stores（唯一允許出現未文件化訊號的地方，ADR-004） |
| `ThresholdDiagnostics` | 葉 target：環形緩衝、privacy filter、匯出 |
| `ThresholdRuntime` | `Coordinator` actor、diagnostics bridge、wiring |
| `ThresholdAppKit` | `AppContainer` composition root、`AppModel`、onboarding／calibration 狀態機 |
| `ThresholdApp` | SwiftUI `MenuBarExtra` 與 `@main`，僅此而已 |

## 工具

| 工具 | 用途 |
|---|---|
| `Tools/rssi-record` | **維護中**。MVP 1B field recorder，驅動 production 的 `CoreBluetoothScanner`，把實機訊號寫成 `Tests/Fixtures/BLE/` 的匿名 replay fixture，並輸出 SPIKE-009 §C 指標。內含補完 SPIKE-009 矩陣的逐項 field protocol |
| `Tools/spikes/ble-observe` | Throwaway。SPIKE-009／004 的掃描探針 |
| `Tools/spikes/screen-state` | Throwaway。SPIKE-001／007／008 的鎖定與 idle 探針 |
| `Tools/spikes/wake-display` | Throwaway。SPIKE-003 的 `IOPMAssertionDeclareUserActivity` 探針 |

Spike 產出的原始資料在 `Tools/spikes/out/`，**已 gitignore**：含 `CBPeripheral.identifier` 與裝置廣播名稱。

## Spike 狀態

**未執行前不寫結果。** 有量測但成功條件未完整驗證時為 `PARTIAL`，每份 PARTIAL 文件內都有 `## Evidence` 與明確的「Not yet measured」清單。

| ID | 問題 | 阻擋 | 順序 | Status |
|---|---|---|---|---|
| SPIKE-009 | 我們宣稱支援的裝置能否被穩定觀察 | MVP 1A | **1** | PARTIAL（2026-09-03：iPhone CONDITIONAL GO；Watch 僅近距離；iPad CONDITIONAL） |
| SPIKE-004 | CoreBluetooth 生命週期 | MVP 1A | 1（同批） | PARTIAL（2026-09-02） |
| SPIKE-001 | 鎖定狀態偵測 | MVP 3 | 2（MVP 2 期間） | PARTIAL（2026-09-02） |
| SPIKE-007 | 鎖定方法 | MVP 3 | 2 | PARTIAL（路徑①傾向 GO，n=16／50，2026-09-03） |
| SPIKE-008 | 輸入閒置偵測 | MVP 3（silence policy） | 2 | CONDITIONAL GO（2026-09-02；`.hidSystemState`，鎖定時 nil） |
| SPIKE-003 | 喚醒行為與 system sleep 邊界 | MVP 4 | 3（MVP 3 期間） | PARTIAL（2026-09-02，display sleep 3/3） |
| SPIKE-005 | Apple Watch 解鎖互動 | MVP 4 | 3 | CONDITIONAL GO（掃描不干擾，n=9，2026-09-03） |
| SPIKE-006 | Touch ID 互動 | MVP 4 | 3 | GO（內建鍵盤，n=5，2026-09-03） |
| SPIKE-002 | loginwindow 偵測 | MVP 6 | 4（MVP 5 後） | NOT RUN |

## 支援裝置（evidence-based，2026-09-03）

依 ADR-009，只有 SPIKE-009 有證據的類別才列入，且以 spike 自己的判定用語標示。距離分段（1 m 桌上／3 m 口袋／8 m 隔壁房間、門關上）為 2026-09-03 晚間受控量測，每段 600 s。

| 類別 | 判定 | 證據 | 尚未量測 |
|---|---|---|---|
| iPhone（同 Apple ID） | **CONDITIONAL GO** | 三段 receiving 皆 **100%**；最長 gap 10.2／9.9／9.0 s；RSSI 中位 −50／−60／−68，隨距離單調且四分位區間可分離。**全程鎖定、螢幕熄滅**，隔著關上的門 8 m 仍 100% 可觀測。identifier 跨 ~22.5 h 不變 | `desk-1m` 的 10.2 s 略超過 ≤10 s 門檻；reboot、BT off→on、forget／re-pair；20 分鐘版本的分段 |
| Apple Watch（同 Apple ID） | **CONDITIONAL（僅近距離）** | 1 m 98.4%／gap 9.9 s、3 m 100%／gap 7.1 s | **8 m 不達標**：83.6%、最長 gap 25.7 s、13 次 >10 s 空窗。RSSI 非單調（1 m 中位 −59、3 m −41），不可用於距離校正 |
| iPad（同 Apple ID） | **CONDITIONAL** | 1 h 未控距離：receiving 100%、最長 gap 9.9 s；identifier 跨 ~22.5 h 不變 | 距離分段、reboot、BT off→on、forget／re-pair |
| Generic BLE beacon | UNKNOWN，不列入 | — | 全部 |
| 另一台 Mac／AirPods | 只有觀察，不列入 | 間歇（33%／48% 視窗） | — |

條件的含義：CONDITIONAL 表示「同 Apple ID、藍牙開啟」下達到 SPIKE-009 §C 的門檻（≥ 95%、gap ≤ 10 s），identity 的 reboot／BT 切換情境仍待驗證。**Apple Watch 的條件更窄**：它是「人在座位附近」的良好證據，但在離開距離會失去觀測，不可作為「已離開」的唯一依據——這正是 ADR-008「證據不足不等於不在場」在裝置選擇上的體現。所有量測皆為單一 Apple Silicon Mac（`Mac17,2`，M5）× macOS 26.6.2，`withServices: nil`、`allowDuplicates: true`，不需 companion app、service UUID 或連線。補完方式見 `Tools/rssi-record/README.md` 的 Field protocol。

## Roadmap

| 里程碑 | 內容 | 狀態 |
|---|---|---|
| MVP 0 | Engineering Foundation | 完成 |
| SPIKE-009 | Trusted Device Observability（GO／NO-GO 閘門） | PARTIAL —— 矩陣待實機補完 |
| MVP 1A | BLE Discovery／Observation | 完成 |
| MVP 1B | Recorded Field Data Collection | 工具完成；實機錄製待跑 |
| MVP 2 | Presence Engine | 完成 |
| MVP 3 | Auto Lock | 已實作，待實機驗證 |
| MVP 4 | Wake + Native Handoff | 已實作，待實機驗證 |
| MVP 5 | Public Alpha | 待簽章與 notarization |
| MVP 6 | Security Spike（Assisted Typed Unlock） | 不保證進 v1 |
| v1.0 | Reliable + Secure + Diagnosable + Maintainable | —— |

## 文件地圖

| 位置 | 內容 |
|---|---|
| `docs/specs/architecture.md` | Target 切分、依賴方向、composition root、concurrency |
| `docs/specs/proximity-domain.md` | Domain model、訊號管線、三軸狀態、Policy、ledger、calibration |
| `docs/specs/security.md` | 安全邊界、fail-closed 規則、威脅模型、UnlockSafetyGuard（reserved） |
| `docs/specs/bluetooth.md` | CoreBluetooth adapter、三通道 stream、Sendable 契約 |
| `docs/specs/system-integration.md` | macOS providers／controllers、生命週期、sleep 語意 |
| `docs/specs/testing.md` | 四層測試、fixtures、必備回歸測試、實機矩陣 |
| `docs/decisions/` | ADR-001 … ADR-011 |
| `docs/spikes/` | SPIKE-001 … SPIKE-009 與各自的 Evidence |
| `docs/plans/` | Implementation plans 與 v1.0 recovery roadmap |
| `docs/release.md` | 從 clean checkout 到可散布 `.app`；簽章與 notarization 為 external blocker |

## 授權

核心：Apache-2.0（見 LICENSE）+ DCO + 商標保護（TRADEMARK.md）。詳見 ADR-005。
