# Security Spec

Status: Approved（2026-09-02）。`ThresholdSecurity` 為 **reserved target**，MVP 0–5 不建立。

## 1. 安全邊界

### 1.1 主線模式（Wake + Native Handoff）——唯一的 MVP 模式
App：
- **不持有**登入密碼（Keychain 內沒有本 App 的任何憑證項目）
- **不模擬**輸入密碼（不使用 `CGEvent` 送鍵盤事件）
- **不執行** authentication；authentication 交還 macOS（Touch ID／Apple Watch／密碼）

主線的兩個 system action——`lock` 與 `wake`——都不會降低安全性。因此主線**沒有需要 UnlockSafetyGuard 的動作**；主線的「安全輸入」（`ScreenState`／`SessionState`／`PowerState`）是 Policy 的 `RequiredPreconditions`，屬 Domain。

### 1.2 Assisted Typed Unlock——非 MVP；研究性功能
- Default OFF；三步驟明確 opt-in；UI 以白話標示風險
- 額外要求 Accessibility；只在使用者啟用此功能時要求
- 必須通過 **Security Validation Gate**（§5）才能進正式產品；只要一次失敗即 NO-GO
- 不符合任一 guard condition 即取消；**Unknown = deny**
- MVP 6 才評估；不保證進 v1

## 2. Fail-closed 規則（全產品）

1. **Required preconditions** 任一 `unknown`／不成立 → 不執行任何 proximity-driven action。（`sensor`、`session`、`power`、`screen`、`calibration`）
2. **Sensor 非 healthy** → 不產生任何新的 proximity-driven action，即使最後已知 presence 為 away。UI 必須顯示自動保護已暫停。
3. **Absence of evidence is not evidence of absence**：裝置沉默走 `evidenceExpired` 路徑，且需要第二個 supporting signal（`inputIdle` 已知且夠長）才可鎖；supporting signal 缺席 → 不動作。
4. **Calibration 未 armed** → Auto Lock 與 Wake 不 armed。
5. **Reset 後**（wake／BT reset／session change／devices change）presence 回 `unknown`，需重新累積 `minSamples + confirmDuration` 的證據。
6. **Stale outcome** 不得影響新 episode，不得觸發重派。
7. 鎖定是安全方向：supporting evidence 未知（`inputIdle == nil`）**不阻擋** measuredFar／departureThenSilent 的 lock；但**阻擋** silence-based lock（規則 3）。

## 3. 禁止行為（Prohibited）

| 禁止 | 理由 |
|---|---|
| 在主線模式讀取／儲存／輸入登入密碼 | 產品邊界（ADR-001） |
| 使用 `login.framework`、`SACLockScreenImmediate`、`MediaRemote.framework` 或任何 private framework | ADR-004；macOS 15.4 已證明會被收回 |
| 讀取 `/Library/Bluetooth/*.db`、`com.apple.Bluetooth.plist` | 需完全取用磁碟；裝置名稱改由使用者命名 |
| 為未來功能提前要求 Accessibility／Full Disk Access／Automation | 權限最小化：只在功能啟用時要求 |
| 以 overlay 假鎖定畫面取代系統鎖定 | 不是真正的鎖定（競品反模式） |
| 在 diagnostics／log 記錄密碼、完整 MAC／identifier、裝置名稱以外的裝置資料 | 隱私（ADR-007） |
| 以 `#if PRO` 散佈於核心 | ADR-005 |
| 以 `@unchecked Sendable` 讓 compiler 閉嘴而不附 invariant | ADR-006 |
| 用 sensor failure 推斷使用者離開 | ADR-008 |

## 4. UnlockSafetyGuard（reserved；介面設計，MVP 6 前不實作）

```swift
// ThresholdSecurity（reserved）
struct SecurityContext: Sendable {                       // 由各 provider 在同一時刻採樣；每欄都可為 .unknown
    let screen: ScreenState                              // 需 .locked（雙源一致）
    let session: SessionState                            // 需 .active
    let power: PowerState                                // 需 .awake，且 wake 後已過 wakeSettle
    let loginWindow: LoginWindowState                    // .detected | .notDetected | .unknown（SPIKE-002 決定訊號組合）
    let secureInput: SecureInputState                    // .enabled | .disabled | .unknown（只是一個 signal，不是 loginwindow 的證明）
    let foregroundApp: ForegroundApplicationState        // .none | .app(bundleID) | .unknown
    let presence: PresenceScore                          // 需 ≥ 0.9 持續 ≥ 3 s 且無 outlier
    let request: UnlockRequest                           // 含 episode、proposedAt、expiresAt
    let recentManualUnlockAt: MonotonicInstant?
    let sampledAt: MonotonicInstant
}

enum SecurityDecision: Sendable, Equatable {
    case allow
    case deny(DenyReason)
    case indeterminate(Field)                            // 等同 deny；分開列只為 diagnostics
}

protocol UnlockSafetyGuarding: Sendable {
    func evaluate(_ context: SecurityContext) -> SecurityDecision
}
```
規則：**ALLOW only when every required signal == affirmative**；沒有發現問題 ≠ allow；任何 `unknown` → `indeterminate` → 視同 deny。檢查項至少：screen definitely locked、session valid、login UI detected、secure input enabled、correct user session、no state transition since proposed、no wake race（wakeSettle）、no foreground application、request not expired、sensor confidence remains valid、rate limit（60 s 內 < 2 次；連續 3 次失敗鎖住功能直到使用者重新確認）。

執行期（若實作）：分段輸入（每段 ≤ 4 字元），**每段前重新 evaluate**；任一段 deny → 立即中止並清除記憶體中的密碼。文件與 UI 必須誠實：分段把外洩從整組密碼降到最多 4 字元，**不是零**。

Providers（reserved，屬 System target）：`LoginWindowProviding`、`SecureInputProviding`、`ForegroundApplicationProviding`；每個都有 Fake，且 Fake 能回報 `.unknown`。

## 5. Security Validation Gate（Assisted Typed Unlock 進產品前）

| 項目 | 條件 |
|---|---|
| Automated | ≥ 500 次 lock/unlock 循環 |
| Race | scheduled unlock + manual unlock |
| Touch ID | pending request 期間 Touch ID 解鎖 |
| Apple Watch | pending request 期間 Watch 解鎖 |
| App focus | 前景為 text editor／browser／terminal |
| Wake races、Sleep races | 邊界前後 |
| Fast User Switching | 切換中與切換後 |

成功條件：**0 unintended keystrokes**。任一次失敗 → NO-GO。不得為保留功能降低標準。

## 6. Threat Model

| 威脅 | 攻擊面 | 主線影響 | Assisted 影響 | 緩解 |
|---|---|---|---|---|
| 憑證外洩 | 打字到錯誤視窗、日誌、記憶體 | 無（不持密碼） | 最高 | 主線不持密碼；Guard；分段；密碼以 `Data` 持有並歸零；日誌永無密碼欄位 |
| BLE 位址偽造 | 複製受信任裝置的廣播 | 只能觸發 wake（無害）與阻止 lock（需持續偽造） | 高 | Apple 裝置使用可解析私有位址（SPIKE-009 驗證）；非 Apple 靜態位址裝置標示較低安全 |
| RSSI 放大／重放 | 遠處裝置看起來很近 | 同上 | 中 | PresenceStable 要求時間一致性；放大器造成的變異數異常 |
| 受信任裝置遭竊 | 帶著裝置走到 Mac 前 | 無（仍需 Touch ID／Watch／密碼） | 高 | 主線設計本身；Assisted 模式誠實告知 |
| Accessibility 濫用 | 惡意程式利用本 App 權限 | 無（主線不要求） | 中 | 無 IPC、Hardened Runtime、不載入外部 plugin |
| 惡意事件腳本 | 替換 event script | 中 | 中 | 固定路徑、擁有者檢查、權限 ≤ 0755、環境變數傳參、不組 shell 字串（MVP 0–4 無此功能） |
| Keychain 存取 | 其他程式讀本 App 項目 | 無（無項目） | 高 | ACL 綁簽章；`ThisDeviceOnly` |
| 權限提升 | 誘導高權限動作 | 低 | 低 | 不需 root；不安裝 helper／daemon |
| 供應鏈 | 相依被植入 | 中 | 中 | 相依只有 Sparkle（MVP 5）；`Package.resolved` 鎖定；CI 乾淨環境 |
| 更新機制遭劫持 | 假 appcast | 最高 | 最高 | Sparkle EdDSA、私鑰離線、HTTPS、公證、SHA256 |
| 感測器失效被當作離開 | BT 關閉 → 鎖螢幕（DoS）或 BT 干擾 → 不鎖（繞過） | 中 | 中 | 三軸正交；sensor 非 healthy 不動作；silence 需 supporting evidence |

## 7. 裝置信任
- 新增受信任裝置需本人確認（`LAContext`：Touch ID／Watch／密碼），防止離座時被加裝置（MVP 5 onboarding）。
- 一鍵「暫停所有自動動作」；移除裝置立即生效並清除其 `CalibrationRecord`。
