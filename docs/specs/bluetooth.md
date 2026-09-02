# Bluetooth Spec

Status: Approved（2026-09-02）；受 SPIKE-009／SPIKE-004 結果約束。

Target：`ThresholdBluetooth`。依賴 Domain、Foundation、CoreBluetooth。**只用 CoreBluetooth**（ADR-004；IOBluetooth 無 MVP 需求）。

## 1. 前提（待驗證，不是事實）
- `scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])` 能持續回報受信任裝置的廣播與 RSSI —— **SPIKE-009**
- 同一 Apple ID 的 Apple 裝置其 `CBPeripheral.identifier` 在同一台 Mac 上跨 restart／reboot 穩定 —— **SPIKE-009**
- sleep／wake 後 CoreBluetooth 狀態序列與是否需重呼叫 `scanForPeripherals` —— **SPIKE-004**

若 SPIKE-009 對某類裝置為 UNSUITABLE，該類裝置從 supported list 移除；**不以 private API 或系統資料庫救**（ADR-009）。

## 2. 介面：三通道

```swift
protocol BLEScanning: Sendable {
    /// Lossy。新資料比舊資料有價值。.bufferingNewest(64)
    var observations: AsyncStream<BLEObservation> { get }
    /// State-bearing。一天幾筆；不可因 RSSI flood 被吃掉；保留 transition 供 diagnostics。.unbounded
    var sensorStates: AsyncStream<Timestamped<SensorStatus>> { get }
    /// 每次呼叫建立新 stream；stopDiscovery() 或 consumer cancel 即 finish。不進監控管線。.bufferingNewest(32)
    func discover() -> AsyncStream<DiscoveredDevice>
    func stopDiscovery()

    func startScanning(for devices: Set<DeviceID>)      // 只 yield 這些裝置；空集合 = 不掃描
    func pause()                                        // systemWillSleep
    func resume()                                       // systemDidWake；內部視 SPIKE-004 結果決定是否重呼叫 scan
    func stopScanning()
}

struct DiscoveredDevice: Sendable, Equatable { let id: DeviceID; let advertisedName: String?; let rssi: Int; let at: MonotonicInstant }
```

`sensorStates` 選 `.unbounded` 的理由：對 Domain 而言 `SensorHealth` 是 latest-state（`bufferingNewest(1)` 就夠），但 diagnostics 需要完整 transition 序列（`resetting → poweredOn` 是 SPIKE-004 的關鍵證據），事件量極低，unbounded 沒有風險。

## 3. CB 狀態映射
| `CBManagerState` | `SensorStatus` |
|---|---|
| `.poweredOn` | `.available` |
| `.poweredOff` | `.unavailable(.poweredOff)` |
| `.unauthorized` | `.unavailable(.unauthorized)` |
| `.unsupported` | `.unavailable(.unsupported)` |
| `.resetting` | `.degraded(.resetting)` |
| `.unknown` | 不 yield（等下一個狀態） |
| stream 意外 finish／central 消失 | `.unavailable(.scannerFailed)`（由 Coordinator 判定並 restart ≤ 3 次） |

## 4. 行為
- **MVP 1 只用 advertisement**：不 connect、不 `readRSSI`。BLEUnlock 的 Active 模式正是藍牙干擾抱怨的來源。`BLEObservation.source = .connectionRead` 保留但不產生。
- 時間：delegate 回呼內以注入的 `MonotonicClock.now()` 打上 `at`。
- 過濾：`didDiscover` 只對 `monitoredDevices` 內的 identifier yield observation；discovery 進行中則另 yield `DiscoveredDevice`。
- 權限：需 `NSBluetoothAlwaysUsageDescription`；`CBCentralManager` 延後建立（見 architecture §5.4）。
- `DeviceRegistry`：`DeviceID ↔ 使用者命名`；持久化為 JSON（System 的 `DeviceStore`）。**不**嘗試取得型號名稱。

## 5. Sendable 契約：`CoreBluetoothScanner`（Option A）

```swift
final class CoreBluetoothScanner: BLEScanning, @unchecked Sendable
```
**Invariant**：所有可變狀態只在 `scanQueue`（serial）上讀寫：
- `central: CBCentralManager?`
- `monitoredDevices: Set<DeviceID>`
- `isPaused: Bool`、`isScanning: Bool`
- `discoveryContinuation: AsyncStream<DiscoveredDevice>.Continuation?`

不可變（`let`，本身 Sendable）：`observationContinuation`、`sensorContinuation`、`clock`、`scanQueue`。

**Enforcement**：
- 每個 public 方法一律 `scanQueue.async { ... }` hop 後才碰狀態
- `CBCentralManager(delegate: self, queue: scanQueue)`——delegate 回呼天然在 queue 上
- Debug build：每個 queue-confined 方法開頭 `dispatchPrecondition(condition: .onQueue(scanQueue))`
- 測試：以 `FakeCentral`（protocol 抽象 `CBCentralManager` 的最小面）注入亂序回呼 + 並發呼叫 public API，斷言 sensor 通道事件序列合法、observation 不外洩非 monitored 裝置

Option B（actor 包 delegate）否決：CB 已提供 serial queue 隔離，再包 actor 只增加一次 hop，不減少任何 invariant（ADR-006）。

## 6. FakeScanner
接受 `[Timestamped<ScannerEvent>]` 或 fixture 檔；`emit(_:)` 手動推送；供 Coordinator 整合測試與 UI 開發。
