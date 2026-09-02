# System Integration Spec

Status: Approved（2026-09-02）；多項受 Spike 約束。

Target：`ThresholdSystem`。依賴 Domain、Foundation、AppKit、IOKit、CoreGraphics、ServiceManagement。**所有會隨 macOS 版本變動的東西集中於此**；每個能力 = `protocol + macOS 實作 + Fake`；Fake 必須能回報 `.unknown`。

## 1. Providers

| Protocol | Production 依據 | API 類別 | Spike | 備註 |
|---|---|---|---|---|
| `ScreenStateProviding` | `DistributedNotificationCenter`：`com.apple.screenIsLocked`／`com.apple.screenIsUnlocked`（transition signal）+ `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`（current state query） | 公開函式、未文件化訊號與鍵 | **SPIKE-001**（PARTIAL 2026-09-02） | 「兩源一致才回報，否則 `.unknown`」是**假說**，不是 production contract。notification 是 transition、query 是 state，時間上不必然同步；Spike 量測 mismatch 持續時間，據此決定 settling window 與 source confidence，避免 provider 長時間卡 `.unknown`。**實測（4 個事件，鎖定 2／解鎖 2）**：未鎖定時 `CGSSessionScreenIsLocked` 這個鍵**不存在**（鎖定時為 `1`），故「取不到鍵」須解讀為 unlocked，不可解讀為 `.unknown`；通知在 4/4 事件中都晚於 query 翻轉 7–110 ms；0 次 mismatch、0 次 false `.unlocked`。500 ms settling window 與目前資料相容，但樣本數遠不足以定案（screen saver、fast user switching、Touch ID／Watch 解鎖皆未測）|
| `SessionStateProviding` | `NSWorkspace.sessionDidBecomeActiveNotification`／`sessionDidResignActiveNotification` + `kCGSessionOnConsoleKey` | 公開 | — | |
| `PowerStateProviding` | `NSWorkspace.willSleepNotification`／`didWakeNotification`／`screensDidSleepNotification`／`screensDidWakeNotification` | 公開 | SPIKE-003 | |
| `InputActivityProviding` | `CGEventSource.secondsSinceLastEventType(_:eventType:)` | 公開；鎖定畫面行為待驗 | **SPIKE-008**（CONDITIONAL GO 2026-09-02） | 規則：`MacOSInputActivityProvider` 用 `.hidSystemState` + `kCGAnyInputEventType`，只在 session active 且 screen unlocked 時回值，否則 `nil`（Policy 對 nil 的處理見 proximity-domain.md §6.3）。歷史：2026-09-02 的嘗試無效：探針傳入 `eventType: .null`（rawValue 0）而非 `kCGAnyInputEventType`（rawValue `UInt32.max`），量到的不是 idle。修正後一筆觀察：`.hidSystemState` 與 IOHIDSystem idle 一致；`.combinedSessionState` 會被 `IOPMAssertionDeclareUserActivity`（本產品的 wake 呼叫）重置 → provider 採 `.hidSystemState`。解鎖後真實輸入兩者即時歸零且一致、免權限；鎖定畫面輸入不重置 `.hidSystemState` → provider 只在 session active 且 screen unlocked 回值，否則 nil。synthetic event／screen saver／fast user switching 未測 |

介面形狀（各 provider 相同）：
```swift
protocol ScreenStateProviding: Sendable {
    var current: ScreenState { get }                     // 同步、執行緒安全的系統查詢
    var changes: AsyncStream<Timestamped<ScreenState>> { get }
}
```

## 2. Controllers

| Protocol | Production 依據 | Spike |
|---|---|---|
| `LockControlling`：`func lock(reason: LockReason) async throws` | 策略待選：① displaySleep（IOKit `IORequestIdle`）+ 系統「睡眠後立即要求密碼」；② ⌃⌘Q via `CGEvent`（需 Accessibility）；③ `shortcuts run "Lock Screen"`（未文件化）；④ `ScreenSaverEngine` | **SPIKE-007** 決定預設與退回順序；主線不要求 Accessibility，故 ② 只在使用者已授權時可選 |
| `WakeControlling`：`func wakeDisplay() async throws` | `IOPMAssertionDeclareUserActivity(_, kIOPMUserActiveLocal, &id)` | **SPIKE-003** |
| `LoginItemControlling` | `SMAppService.mainApp.register()`／`unregister()`／`status` | — |

## 3. Stores
`DeviceStore`、`CalibrationStore`、`SettingsStore`：record 類以 JSON 檔存於 `~/Library/Application Support/<bundle id>/`；簡單設定用 `UserDefaults`。`macIdentity` 以 IOKit 公開的 `IOPlatformUUID` 取得。

## 4. Sleep 語意（產品定義，不做 workaround）

| 狀態 | 預期（待 SPIKE-003／004 驗證） |
|---|---|
| Display asleep、system awake | process 執行、CoreBluetooth 持續掃描、`IOPMAssertionDeclareUserActivity` 可點亮螢幕。**實測（SPIKE-007，n=1，2026-09-02）**：在「睡眠後立即要求密碼」下，顯示器睡眠後 76 ms `CGSSessionScreenIsLocked` 轉 `1`、156 ms `com.apple.screenIsLocked` 抵達，無需權限。**實測（SPIKE-003，n=3，2026-09-02）**：鎖定 + 顯示器睡眠下 `IOPMAssertionDeclareUserActivity` 3/3 於 ≤ 150 ms 點亮、免權限、鎖定不變，登入畫面約 33 s 無輸入後再度熄滅。**實測（SPIKE-004，75 s 與 136 s 兩段，2026-09-02）**：display sleep 下 CoreBluetooth 掃描持續、無 state 事件、樣本率不變 |
| System asleep | user-space process 凍結；CoreBluetooth 不 deliver；**無 supported 機制讓第三方 App 因 BLE presence 喚醒 Mac** |
| Dark Wake／Power Nap | 只給系統服務；不排程第三方 App |
| Apple Silicon vs Intel | 結論相同；差在進入睡眠速度 |
| `pmset schedule wake`／privileged helper | 技術可行，**不做**（需 root helper；是 workaround） |

**產品語意**：Wake on Return 只在「Mac 醒著、顯示器睡眠或鎖定」時有效。Mac 進入完全睡眠後，使用者第一次按鍵／觸碰觸控板喚醒它，之後 Touch ID／Apple Watch 照常接手。

後果：桌機（通常設「顯示器關閉時防止自動睡眠」）幾乎總是醒著，效果完整；筆電用電池會很快睡著，效果退化。「鎖定後保持 Mac 清醒 N 分鐘」的 opt-in（`PreventUserIdleSystemSleep` assertion）為 SPIKE-003 第二實驗與 post-MVP 產品決策。

## 5. Sendable 契約
- Providers：`final class: Sendable`；stored property 只有 `let continuation`（Sendable）與 `OSAllocatedUnfairLock<State>` 包住的 observer token；通知在 main thread 抵達 → yield。不需 `@unchecked`。
- Controllers：`final class: Sendable`，無可變狀態。
- `ContinuousMonotonicClock: MonotonicClock`：`struct` 包 `ContinuousClock`。

## 6. 權限
| 權限 | 等級 | 何時 |
|---|---|---|
| Bluetooth | 必要 | onboarding 第一步 |
| Notifications | 選用 | onboarding 尾端（MVP 5） |
| Login Item | 選用 | onboarding 尾端（MVP 5） |
| Accessibility | 選用 | 只在使用者選擇需要它的鎖定策略或（未來）Assisted Unlock 時 |
| Full Disk Access、Camera、Location | 禁止 | — |

原則：**Request only when feature requires it.**

## 7. 未文件化訊號的隔離
`com.apple.screenIsLocked`、`CGSSessionScreenIsLocked`、`shortcuts run` 行為只出現在 `ThresholdSystem` 的對應 provider／controller 內；任何一個失效時，只替換該實作，Domain 與 Coordinator 不動。每年 WWDC 後一週內對 beta 跑相容性 CI（`macos-beta.yml`）。
