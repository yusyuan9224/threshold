# Bluetooth Spec

Status: Approved（2026-09-02）；受 SPIKE-009／SPIKE-004 結果約束。

Target：`ThresholdBluetooth`。依賴 Domain、Foundation、CoreBluetooth。**只用 CoreBluetooth**（ADR-004；IOBluetooth 無 MVP 需求）。

## 1. 前提（待驗證，不是事實）
- `scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])` 能持續回報受信任裝置的廣播與 RSSI —— **SPIKE-009**
- 同一 Apple ID 的 Apple 裝置其 `CBPeripheral.identifier` 在同一台 Mac 上跨 restart／reboot 穩定 —— **SPIKE-009**
- sleep／wake 後 CoreBluetooth 狀態序列與是否需重呼叫 `scanForPeripherals` —— **SPIKE-004**

若 SPIKE-009 對某類裝置為 UNSUITABLE，該類裝置從 supported list 移除；**不以 private API 或系統資料庫救**（ADR-009）。

### Evidence so far（2026-09-02；SPIKE-009／004 = PARTIAL，契約不變）
量測環境：一台 Apple Silicon Mac × macOS 26.6.2，Mac 全程清醒；600 s 連續掃描 + 一次 60 s 掃描。細節與「未測項目」見 `docs/spikes/SPIKE-009-*.md`、`SPIKE-004-*.md`。

- `withServices: nil` + `allowDuplicates: true` 在 600 s 內對同 Apple ID 的 iPhone、Apple Watch、iPad 每個 10 s 視窗都有樣本，節奏約 0.8–1.0 筆/秒；不需 companion app、不需已知 service UUID、不需連線。
- 同一台 Mac 上兩個相隔 53 s 的獨立 scanner process，11 個具名裝置的 `CBPeripheral.identifier` 全部相同。**reboot、BT off→on、24 h 尺度的穩定性仍未驗證**，§1 的第二條前提維持「待驗證」。
- 同一房間 600 s 內出現 56 個唯一 identifier，每 10 s 視窗平均 22 個活躍，其中 12 個生命期 < 10 s。`DeviceRegistry` 與 discovery UI 必須承受這個雜訊量，且不可假設每個 identifier 對應一個持續存在的裝置。
- 廣播的 RSSI 可能是 `127`（CoreBluetooth 的「數值不可用」哨兵值，56 個 identifier 中有 5 個出現過）。若不處理會被當成極近距離。這是實測發現，**尚未寫入 §4 契約**。
- `CBManagerState` 在兩回合都是 `.unknown → .poweredOn` 一次到位，之後 66 個 10 s 取樣點全部 `.poweredOn` 且 `isScanning == true`，未出現 `.resetting`。`.unknown → .poweredOn` 的延遲在兩回合分別為 3 037 ms 與 59 ms，故建立 `CBCentralManager` 後必須容忍數秒的 `.unknown`。
- **display sleep 與 system sleep 完全未測**，§4 的 `pause()`／`resume()` 行為沒有任何實測支撐。

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
- **射頻中斷後的恢復（SPIKE-004 實測，2026-09-03）**：Mac 端 Bluetooth off→on 產生 `poweredOn → poweredOff → poweredOn`，中間**不**出現 `.resetting`。`CoreBluetoothScanner` 在狀態回到 `poweredOn` 後自行恢復掃描，呼叫端**不需**重新呼叫 `startScanning(for:)`；射頻恢復到第一筆 observation 約 6 s。中斷期間的樣本空窗表達為 sensor 軸的 `unavailable.poweredOff`，**不**表達為 device 軸的 silence。監看中的 `CBPeripheral.identifier` 跨中斷不變。

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
