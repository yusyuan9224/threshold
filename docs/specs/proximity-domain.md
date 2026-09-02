# Proximity Domain Spec

Status: Approved（Domain sign-off 2026-09-02）

Target：`ThresholdDomain`。只依賴 Swift stdlib；無副作用；所有函式對相同輸入回傳相同輸出。

## 0. 原則

- **Domain owns temporal rules but never owns time.**（ADR-003）——時間只以輸入的 `MonotonicInstant` 出現；Domain 從不呼叫 clock。
- **Absence of evidence is not evidence of absence.**（ADR-008）——裝置沉默是「失去證據」，不是「使用者離開」。
- Raw RSSI 永遠不能直接產生 system action：`BLEObservation → Signal → Presence Evidence → ProximitySnapshot → PolicySnapshot → PolicyAction → System adapter`，不可跳層。
- 三軸正交：`PresenceState`（相信使用者在哪）、`SensorHealth`（感測子系統可不可信）、`DeviceObservationState`（每個裝置有沒有講話）。

## 1. Observation/

```swift
struct DeviceID: Hashable, Codable, Sendable { let raw: String }       // CoreBluetooth identifier 字串；Domain 不知道它是 UUID

struct MonotonicInstant: Comparable, Hashable, Codable, Sendable {      // 單調時間；禁止持久化；不可跨 reboot
    let nanoseconds: Int64
    static func + (lhs: Self, rhs: Duration) -> Self
    static func - (lhs: Self, rhs: Self) -> Duration
}
// 間隔一律用 Swift stdlib `Duration`（整數表示），不用 Double 秒。

struct BLEObservation: Codable, Sendable, Equatable {
    let device: DeviceID
    let at: MonotonicInstant
    let rssi: Int                       // dBm
    let source: Source                  // .advertisement（MVP 唯一來源）| .connectionRead（保留，MVP 不產生）
}

enum SensorStatus: Codable, Sendable, Equatable {   // 由 Bluetooth adapter 產生；描述感測器本身
    case available
    case degraded(DegradedReason)       // .resetting | .scanInterrupted
    case unavailable(UnavailableReason) // .poweredOff | .unauthorized | .unsupported | .scannerFailed
}

struct Timestamped<T: Sendable>: Sendable { let value: T; let at: MonotonicInstant }
```

### 1.1 ObservationValidator（純函式）
輸入 `BLEObservation` + 該裝置最後接受的 `at` + registry 內 device 集合。規則：
1. `rssi ∉ [-120, 0]` → 丟棄，理由 `.rssiOutOfRange`
2. `device` 不在 registry → 丟棄，`.unknownDevice`
3. `at < lastAccepted − maxSkew(1 s)` → 丟棄，`.outOfOrder`（並回報 `.clockAnomaly` 供 diagnostics）
4. 其餘接受

丟棄理由以回傳值 `ValidationResult` 表達，供外層記錄。

## 2. Signal/

每個裝置一條管線，全部參數在 `EngineConfiguration`：

```text
accepted observation
→ SignalWindow      保留最近 windowSize(7) 筆 (rssi, at)；比 horizon(15 s) 舊的移除
→ MedianFilter      最近 medianSpan(5) 筆的中位數（不足 5 筆用現有筆數）→ 單筆 spike 不進 EMA
→ EMAFilter         alpha(0.3)；輸出 smoothedRSSI
→ SignalEstimate    { smoothedRSSI, sampleCount, lastSeen, spread(window 的 MAD) }
```

## 3. Presence/

### 3.1 PresenceScore（三個因子，各一句話理由）
```swift
struct PresenceScore: Sendable, Equatable {
    let value: Double          // distance × recency × sufficiency ∈ [0, 1]
    let distance: Double       // logistic((smoothedRSSI − midpoint) / slope)：訊號相對校正基線有多「近」
    let recency: Double        // 1 若 age ≤ 2 s；線性衰減至 0 於 age = silentThreshold(10 s)：只平滑沉默前最後幾秒，**不能**把分數拉到 0 造成假 away
    let sufficiency: Double    // min(1, sampleCount / minSamples(5))：樣本不足時不可信
}
```
`midpoint`／`slope` 來自 `CalibrationGate.armed(profile)`；`notArmed` 時使用 `CalibrationProfile.default`（midpoint −70、slope 6）**僅供顯示**，永遠不會讓 Policy 動作（見 §7）。

### 3.2 DeviceObservationState（軸 3）
```swift
enum DeviceObservationState: Sendable, Equatable { case receiving; case silent(since: MonotonicInstant) }
```
- `receiving → silent(since: lastSeen)`：該裝置 `now − lastSeen > silentThreshold(10 s)`
- `silent → receiving`：收到有效 observation

### 3.3 DeviceTrack
```swift
struct DeviceTrack: Sendable, Equatable {
    let device: DeviceID
    let observation: DeviceObservationState
    let estimate: SignalEstimate?
    let score: PresenceScore?          // 只在 receiving 且 estimate 存在時有值
    let isCalibrated: Bool
}
```

### 3.4 PresenceFusion（seam）
```swift
protocol PresenceFusion: Sendable { func fuse(_ tracks: [DeviceTrack]) -> Double? }   // nil = 沒有任何 receiving 裝置
struct AnyDeviceFusion: PresenceFusion   // MVP 唯一實作：receiving 裝置分數的 max；無 receiving → nil
```
**fused score 只從 `receiving` 的裝置計算。** 這是把 silence 與 absence 分開的機制核心。多裝置未來只加 fusion 策略；狀態機與轉換表不變。

## 4. StateMachine/

### 4.1 三軸
```swift
enum PresenceState: Sendable, Equatable { case unknown(UnknownReason); case present; case departing; case away }
enum UnknownReason: Sendable, Equatable { case initial; case evidenceExpired; case reset(ResetReason); case sensorRestored }
enum ResetReason: Sendable, Equatable { case systemWake; case bluetoothReset; case sessionChanged; case devicesChanged }

enum SensorHealth: Sendable, Equatable {
    case initializing
    case healthy
    case degraded(DegradedReason)
    case unavailable(UnavailableReason)
}

enum PresenceEvidence: Sendable, Equatable { case none; case measuredNear; case measuredFar; case departureThenSilent }

enum TransitionCause: Sendable, Equatable {
    // presence 軸
    case confirmedNear, measuredFar, signalWeakened, signalRecovered, departureThenSilent, evidenceExpired
    case reset(ResetReason), sensorRestored
    // sensor 軸
    case sensorBecameHealthy, sensorDegraded(DegradedReason), sensorUnavailable(UnavailableReason), sensorInitializing
    // device 軸
    case deviceSilent, deviceReceiving
}
enum Axis: Sendable, Equatable { case presence; case sensor; case device(DeviceID) }
```

### 4.2 引擎
```swift
enum EngineInput: Sendable {
    case observation(BLEObservation)
    case sensor(SensorStatus, at: MonotonicInstant)
    case tick(at: MonotonicInstant)                      // 外層依 nextDeadline 排程
    case reset(ResetReason, at: MonotonicInstant)
}

struct ProximitySnapshot: Sendable, Equatable {
    let presence: PresenceState
    let presenceSince: MonotonicInstant
    let episode: EpisodeID                               // 每次 presence transition 遞增（UInt64）
    let evidence: PresenceEvidence                       // provenance 不丟失
    let lastTransition: TransitionCause?
    let sensor: SensorHealth
    let devices: [DeviceID: DeviceTrack]
    let nextDeadline: MonotonicInstant?
}

struct ProximityTransition: Sendable, Equatable {
    let axis: Axis                                       // .presence | .sensor | .device(DeviceID)
    let from: String; let to: String                     // 各軸各自的狀態描述（診斷用）
    let at: MonotonicInstant
    let cause: TransitionCause
}

struct ProximityEngine {                                 // 非 Sendable；只由 Coordinator 持有
    init(configuration: EngineConfiguration, fusion: any PresenceFusion, devices: Set<DeviceID>, gate: CalibrationGate)
    mutating func handle(_ input: EngineInput) -> [ProximityTransition]
    mutating func update(gate: CalibrationGate)          // 校正改變不 reset presence
    var snapshot: ProximitySnapshot { get }
}
```

### 4.3 Presence 軸轉換表

Initial Tunable Defaults（`EngineConfiguration`）：`enter 0.7`、`exit 0.3`、`confirmDuration 3 s`、`departureDelay 10 s`、`silentThreshold 10 s`、`evidenceTimeout 30 s`、`minSamples 5`、`departureSilentLookback k = 3`、`unknownGrace 30 s`。

| # | 從 | 到 | 條件 | cause | evidence |
|---|---|---|---|---|---|
| 1 | unknown | present | ≥1 receiving；samples ≥ minSamples；fused ≥ enter 持續 ≥ confirmDuration | `.confirmedNear` | measuredNear |
| 2 | unknown | away | 同上但 fused < exit | `.measuredFar` | measuredFar |
| 3 | present | departing | fused < exit（量測到，非沉默） | `.signalWeakened` | measuredNear（未變） |
| 4 | departing | present | fused ≥ enter | `.signalRecovered` | measuredNear |
| 5 | departing | away | 停留 ≥ departureDelay，仍有 receiving 且 fused < exit | `.measuredFar` | measuredFar |
| 6 | departing | away | 所有裝置 silent；沉默前最後 k 筆 fused 全 < exit；自進入 departing ≥ departureDelay | `.departureThenSilent` | departureThenSilent |
| 7 | departing | unknown | 所有裝置 silent ≥ evidenceTimeout，且不滿足 #6 前兆 | `.evidenceExpired` | none |
| 8 | present | unknown | 所有裝置 silent ≥ evidenceTimeout | `.evidenceExpired` | none |
| 9 | away | present | fused ≥ enter 持續 ≥ confirmDuration | `.confirmedNear` | measuredNear |
| 10 | away | unknown | 所有裝置 silent ≥ evidenceTimeout | `.evidenceExpired` | none |
| 11 | 任何 | unknown | `reset(reason)`；或 sensor 從非 healthy 回到 healthy | `.reset(reason)` / `.sensorRestored` | none |
| — | unknown | unknown | 超過 unknownGrace 仍不足 minSamples：**不轉換**，回報 `.presenceUncertain` rationale | | |

**語意註記**：
- `.measuredFar`：有量測到的遠距證據。
- `.departureThenSilent`：**比突然沉默更強的 absence 證據，不是確認離開**。訊號先弱再消失也可能來自干擾、廣播節奏改變、OS lifecycle、裝置方向。State 同樣進 `away`，但 evidence provenance 保留，Policy 可獨立調整（§6）。
- `.evidenceExpired`：失去證據，不是 absence。

### 4.4 Sensor 軸
`initializing → healthy`（scanner 啟動且 `.available`）；`healthy → degraded(r)`；`degraded → healthy`；`任何 → unavailable(r)`；`unavailable → initializing`（收到 `.available`，隨即 → healthy）。Sensor 軸轉換**從不改寫 presence**，只在恢復 healthy 時觸發 presence #11。Sensor 非 healthy 期間 presence 保留最後已知值（供 UI 顯示「最後已知」），Policy 不動作。

### 4.5 Deadline
`nextDeadline` = min(confirmDuration 到期、departureDelay 到期、各裝置 silentThreshold 到期、evidenceTimeout 到期、unknownGrace 到期)。外層只需在該時刻送 `.tick`；提前 tick 無害。

## 5. Reset 與恢復
`reset(reason)`：presence → `unknown(.reset(reason))`、episode 遞增、tracks 清空（`estimate`／`score` 為 nil、observation 為 `receiving` 待判定）、deadline 重算；`CalibrationGate` 保留。從 `unknown` 離開需要 `minSamples + confirmDuration`，因此**喚醒後 3 秒內不可能鎖定**（回歸測試）。

## 6. Policy/

### 6.1 輸入
```swift
struct RequiredPreconditions: Sendable, Equatable {      // 任一 unknown / 不成立 → 不得執行 action
    let sensor: SensorHealth        // 必須 .healthy
    let session: SessionState       // 必須 .active
    let power: PowerState           // lock 需 .awake；wake 需 .displayAsleep
    let screen: ScreenState         // lock 需 .unlocked；wake 需 .locked
    let calibration: CalibrationGate // 必須 .armed
    func check(for kind: ActionKind) -> PreconditionResult   // .satisfied | .unsatisfied(Field) | .indeterminate(Field)
}
struct SupportingEvidence: Sendable, Equatable {         // unknown 時由各規則決定
    let inputIdle: Duration?
}
enum ScreenState: Sendable, Equatable { case unlocked, locked, unknown }
enum SessionState: Sendable, Equatable { case active, inactive, unknown }
enum PowerState: Sendable, Equatable { case awake, displayAsleep, systemAsleep, unknown }

struct PolicySettings: Codable, Sendable, Equatable {
    var autoLock: Bool = true
    var wakeOnReturn: Bool = true
    var lockOnDepartureThenSilent: Bool = true           // 獨立開關：departureThenSilent 證據可否觸發 lock
    var silenceLock: SilenceLockPolicy = .afterTimeout(.seconds(180))   // .never | .afterTimeout(Duration)
    var departedIdleGuard: Duration = .seconds(15)       // measuredFar / departureThenSilent 的輸入活動守衛
    var silenceIdleGuard: Duration = .seconds(60)
    var wakeWindow: Duration = .seconds(30)
}

struct PolicySnapshot: Sendable {
    let proximity: ProximitySnapshot
    let preconditions: RequiredPreconditions
    let evidence: SupportingEvidence
    let settings: PolicySettings
    let now: MonotonicInstant
}
enum PolicyTrigger: Sendable { case presence, sensor, screen, session, power, input, settings, calibration, deadline, actionOutcome }
```

### 6.2 輸出與引擎
```swift
enum ActionKind: Sendable, Equatable { case lock(LockReason); case wake }
enum LockReason: Sendable, Equatable { case userDeparted(PresenceEvidence); case evidenceExpired }
struct ActionID: Hashable, Sendable { let raw: UInt64 }
struct EpisodeID: Hashable, Sendable { let raw: UInt64 }

struct PolicyAction: Sendable, Equatable { let id: ActionID; let kind: ActionKind; let episode: EpisodeID; let proposedAt: MonotonicInstant }
struct PolicyOutput: Sendable { let action: PolicyAction?; let nextDeadline: MonotonicInstant?; let rationale: [PolicyRationale] }

enum ActionOutcome: Sendable, Equatable { case completed; case failed(String) }

struct PolicyEngine {                                    // 非 Sendable；只由 Coordinator 持有
    mutating func evaluate(_ snapshot: PolicySnapshot, trigger: PolicyTrigger) -> PolicyOutput
    mutating func acknowledge(actionID: ActionID, episodeID: EpisodeID, outcome: ActionOutcome, at: MonotonicInstant) -> AcknowledgeResult   // .applied | .stale
}
```
決策是 `PolicySnapshot` 的純函式 + 引擎自身 ledger；`trigger` 不參與決策，只進 rationale。任何輸入變化都重評，因此「away 時 screen unknown、100 ms 後 screen 變 unlocked」由 `.screen` trigger 的重評解決，不需 presence 再轉換。

### 6.3 規則

**Lock**（preconditions.check(.lock) == .satisfied 為前提）
- `presence == .away` 且 `evidence == .measuredFar`：`inputIdle == nil` **允許**；`inputIdle < departedIdleGuard` → `.none(.userActive)`；否則 `.lock(.userDeparted(.measuredFar))`
- `presence == .away` 且 `evidence == .departureThenSilent`：需 `settings.lockOnDepartureThenSilent`；idle 規則同上；→ `.lock(.userDeparted(.departureThenSilent))`
- `presence == .unknown(.evidenceExpired)`：需 `silenceLock == .afterTimeout(d)`；`inputIdle == nil` → `.none(.insufficientEvidence)`（沉默只有失去證據，第二個 supporting signal 也缺席就不推斷 absence）；`inputIdle < silenceIdleGuard` → `.none(.userActive)`；`presenceSince + d > now` → `.none(.waiting)` 並回傳 `nextDeadline`；否則 `.lock(.evidenceExpired)`
- 其他 presence → `.none(.noAbsenceEvidence)`

**Wake**（preconditions.check(.wake) == .satisfied 為前提）
- `settings.wakeOnReturn` 且 `presence == .present` 且 `now − presenceSince ≤ wakeWindow` → `.wake`；wakeWindow 保證只在**到達邊緣**喚醒，人坐在鎖定的 Mac 前不會反覆亮螢幕
- 否則 `.none`

**Preconditions 不成立**：`.none(.preconditionIndeterminate(field))` 或 `.none(.preconditionUnsatisfied(field))`。明文後果：sensor 非 healthy 時，即使 presence 最後已知為 away 且 screen unlocked，**不會鎖**——這是「感測器失效不得驅動動作」的代價，UI 必須顯示「藍牙不可用，自動保護已暫停」。

### 6.4 Action ledger（去重與 stale 保護）
```swift
struct LedgerEntry { let id: ActionID; let kind: ActionKind; let episode: EpisodeID; var stage: Stage; var attempts: Int; var issuedAt: MonotonicInstant }
enum Stage { case proposed, issued, acknowledged, confirmed, failed, stale, gaveUp }
```
- **Lock**：同一 episode 最多一個 entry。issued 後：snapshot 觀察到 `screen == .locked` → `confirmed`；`retryAfter(5 s)` 後 screen 仍 unlocked 且非 failed → 重發（`attempts ≤ maxAttempts(3)`）；超過 → `gaveUp` + rationale。episode 改變 → 舊 entry 作廢。
- **Wake**：同一 arrival episode 一次，不重試。
- **acknowledge**：entry 不存在或 `episode ≠ episodeID` → 回傳 `.stale`，ledger 不變，不重派；`.failed` 立即允許（受 attempts 限制的）重試。
- **cancellable vs committed**：只有 `proposed` 可取消；`issued` 起 effect 已 committed。

## 7. Calibration/

### 7.1 型別
```swift
struct CalibrationProfile: Codable, Sendable, Equatable { let nearBaseline: Double; let farBaseline: Double; let noise: Double; let midpoint: Double; let slope: Double; static let `default`: Self }
struct CalibrationRecord: Codable, Sendable, Equatable {   // 持久化單位；禁止含 MonotonicInstant
    let device: DeviceID; let macIdentity: String
    let profile: CalibrationProfile
    let osMajorVersion: Int; let appVersion: String
    let createdAtUnixSeconds: Int64                       // wall-clock，只用於顯示與（若啟用的）過期判斷
}
enum CalibrationGate: Sendable, Equatable { case armed(CalibrationProfile); case notArmed(NotArmedReason) }
enum NotArmedReason: Sendable, Equatable { case noProfile, deviceMismatch, macMismatch, needsRevalidation(osMajorChanged: Bool), driftExceeded, invalid(CalibrationFailure) }
enum CalibrationFailure: Sendable, Equatable { case insufficientSamples(phase: Phase), overlap, tooNoisy(phase: Phase) }
```

### 7.2 CalibrationSession（純邏輯；UI 只餵樣本）
兩段：`near`（在座位）與 `far`（平常會離開的距離），各 `minDuration 20 s` 且 `minSamples 15`。輸出 profile 或 failure：
- 任一段樣本 < minSamples → `.insufficientSamples`
- 任一段 MAD > `maxNoiseDB(6)` → `.tooNoisy`
- `median(near) − median(far) < max(minSeparationDB(8), 3 × max(MAD near, MAD far))` → `.overlap`（比默默給壞門檻誠實）
- 成功：`nearBaseline = median(near)`、`farBaseline = median(far)`、`noise = max(MAD)`、`midpoint = (near+far)/2`、`slope = (near−far)/4`

### 7.3 Gate 規則（`CalibrationValidator.gate(record, context)`）
- 無 record → `.noProfile`
- `record.device ≠ device` → `.deviceMismatch`；`record.macIdentity ≠ 現在的 macIdentity`（IOKit 公開 IOPlatformUUID）→ `.macMismatch`
- `record.osMajorVersion ≠ 現在` → `.needsRevalidation(osMajorChanged: true)`
- `CalibrationPolicy.maxProfileAge` 非 nil 且超齡 → `.needsRevalidation(osMajorChanged: false)`
- 其餘 → `.armed(profile)`

**Revalidation**（`CalibrationValidator.revalidate(record, nearSamples)`）：只做 near 段；`median(near)` 落在 `nearBaseline ± max(6 dB, 2×noise)` → 直接 re-arm（原 profile 不變）；否則要求完整校正。record **不刪除**。

### 7.4 CalibrationPolicy — Initial Tunable Defaults
以下數值**沒有實測依據**，是工程初始值，待 MVP 1B 實錄資料與 alpha issue 調整；不是產品需求。
```swift
struct CalibrationPolicy: Codable, Sendable {
    var maxProfileAge: Duration? = nil            // age-based revalidation：架構支援，MVP 停用
    var driftSuspectThresholdDB: Double = 8
    var driftWindow: Duration = .seconds(1800)
    var autoDisarmOnDrift: Bool = false           // post-MVP decision；預設關
    var driftDisarmThresholdDB: Double = 15
}
```

### 7.5 DriftDetector（純函式；MVP 只偵測 → diagnostics → 建議重校正）
輸入：record、在「強證據在座位」條件（`presence == present ∧ screen == unlocked ∧ inputIdle < 30 s`）下累積的 smoothedRSSI 樣本、policy。輸出 `DriftAssessment`：`.none`／`.suspected(deviationDB)`／`.exceeded(deviationDB)`。`exceeded` 只在 `autoDisarmOnDrift == true` 時影響 gate。

## 8. Persistence 與 memory

| 持久化（App 透過 System stores） | 只在記憶體 |
|---|---|
| `DeviceRegistry`（DeviceID、使用者命名） | `ProximityEngine` 全部狀態、tracks、episode、deadline |
| `CalibrationRecord`（每裝置） | `PolicyEngine` ledger |
| `PolicySettings`、`EngineConfiguration`／`CalibrationPolicy` 覆寫 | `RequiredPreconditions` 的系統狀態（每次由 provider 現讀） |

runtime evidence／presence／`MonotonicInstant` **不跨 process lifecycle 保存**。型別上 `CalibrationRecord` 不含 `MonotonicInstant`。
