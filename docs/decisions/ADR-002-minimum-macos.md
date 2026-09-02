# ADR-002 Minimum macOS Version
Status: Accepted (2026-09-02)

## Context
macOS 27 於 2026-09 釋出且僅支援 Apple Silicon；競品 ProximityLock／Peeku 支援 14+。Observation 框架、成熟的 `MenuBarExtra`、`SMAppService` 在 14 齊備。

## Decision
Deployment target **macOS 14.0**，universal binary（arm64 + x86_64）。不為 13 或更早增加相容抽象。每年 WWDC 後重評；macOS 14 裝機量 < 10% 時提升至 15；v2 為放棄 Intel 的自然時點。

## Alternatives
13（缺 Observation、MenuBarExtra bug）、15（收益不明顯）、26（裝機量太小）。

## Consequences
可用 `@Observable`、Swift 6 全功能；需維持 universal build。
