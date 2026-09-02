# Threshold

> A security-first macOS proximity application that automatically protects the Mac when the user leaves and prepares it for secure native authentication when the user returns.

工作代號 **Threshold**（正式命名前需做商標檢索）。本 repo 目前處於 **規格階段**：尚無 production code，只有規格、決策紀錄與實驗計畫。

## 核心理念

```text
Presence Detection → Automatic Protection → Native Authentication Handoff
```

App **不持有登入密碼、不模擬輸入密碼、不執行 authentication**；authentication 交還給 macOS（Touch ID／Apple Watch／密碼）。

## 三條原則（見 docs/decisions）

1. Domain owns temporal rules but never owns time.（ADR-003）
2. Absence of evidence is not evidence of absence.（ADR-008）
3. A device is supported only if its presence can be observed reliably through supported APIs.（ADR-009）

## 文件地圖

| 位置 | 內容 |
|---|---|
| `docs/specs/architecture.md` | Target 切分、依賴方向、composition root、concurrency |
| `docs/specs/proximity-domain.md` | Domain model、訊號管線、三軸狀態、Policy、ledger、calibration |
| `docs/specs/security.md` | 安全邊界、fail-closed 規則、威脅模型、UnlockSafetyGuard（reserved） |
| `docs/specs/bluetooth.md` | CoreBluetooth adapter、三通道 stream、Sendable 契約 |
| `docs/specs/system-integration.md` | macOS providers／controllers、生命週期、sleep 語意 |
| `docs/specs/testing.md` | 四層測試、fixtures、必備回歸測試、實機矩陣 |
| `docs/decisions/` | ADR-001 … ADR-010 |
| `docs/spikes/` | SPIKE-001 … SPIKE-009（尚未執行；沒有結果就沒有結果） |
| `docs/plans/` | Superpowers implementation plans（MVP 0 起） |

## Roadmap

```text
MVP 0  Engineering Foundation
SPIKE-009  Trusted Device Observability（GO / NO-GO）
MVP 1A BLE Discovery / Observation
MVP 1B Recorded Field Data Collection
MVP 2  Presence Engine
MVP 3  Auto Lock
MVP 4  Wake + Native Handoff
MVP 5  Public Alpha
MVP 6  Security Spike（Assisted Typed Unlock；不保證進 v1）
v1.0   Reliable + Secure + Diagnosable + Maintainable
```

## 授權

核心：Apache-2.0（LICENSE 於 MVP 0 加入）+ DCO + 商標保護。詳見 ADR-005。
