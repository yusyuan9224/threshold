# ADR-005 Open-source / Pro Boundary
Status: Accepted (2026-09-02)

## Context
核心將以 Apache-2.0 公開；未來可能有付費 Pro。開源 build 不應充滿 `#if PRO`。

## Decision
- 核心（本 repo 全部）：**Apache-2.0 + DCO（Signed-off-by）+ 商標保護（TRADEMARK.md）**。不使用 CLA。
- Pro：獨立私有 repo 的 Swift package，以 `.package(path:)`／tag 依賴本 package；擴充點在 `AppContainer` 的組裝階段。
- **現在不定義 `ProFeatureProvider` 或任何 feature flag／entitlement／license 抽象**；等第一個 Pro consumer 出現再定義。
- 安全功能永不 paywall：security fixes、signal handling 安全性、核心鎖定、權限安全、security guards、macOS 相容性、更新機制。

## Alternatives
MIT（缺專利與商標條款）、GPL／AGPL（與 open core 衝突且需 CLA）、BSL（削弱「可審查安全核心」訴求）。

## Consequences
他人 fork 商業化合法；護城河在維護信譽、商標、校正資料與產品打磨。
