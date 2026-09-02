# Architecture Overview（索引）

正式規格在 `docs/specs/`。本目錄保留圖與跨規格的總覽。

```text
CoreBluetooth / macOS notifications          ← 邊界：時間在這裡打上（MonotonicClock）
        ↓ AsyncStream<value type>
   Coordinator (actor)                        ← 只做編排：快取、deadline、呼叫引擎、派發動作、回收 outcome
        ↓ 純 struct，只被 actor 持有
   ProximityEngine → ProximitySnapshot
   PolicyEngine    → PolicyAction
        ↓
   System controllers (Lock / Wake)           ← 唯一會產生副作用的地方
        ↓ outcome
   Coordinator（acknowledge，含 stale 保護）
```

依賴方向（`Package.swift` 強制）：

```text
ThresholdDomain        ← 只依賴 Swift stdlib
ThresholdBluetooth     → Domain
ThresholdSystem        → Domain
ThresholdDiagnostics   → Foundation, os.log（無其他 target 依賴它，只有 App 用）
Threshold (App)        → 全部
```
