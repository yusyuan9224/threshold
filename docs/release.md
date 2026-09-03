# Release Procedure

本文件描述從 clean checkout 到可散布 `Threshold.app` 的完整步驟。第 1–3 節可在本機與 CI 完整執行；**第 4 節（簽章與 notarization）目前是 EXTERNAL BLOCKER**，缺少憑證，任何人都無法在本 repo 內完成。

## 1. 前置條件

| 項目 | 值 | 來源 |
|---|---|---|
| Deployment target | macOS 14.0 | ADR-002、`Package.swift`、Info.plist `LSMinimumSystemVersion` |
| Swift language mode | 6 | `Package.swift` `swiftLanguageModes: [.v6]` |
| 開發機（2026-09-02） | Apple Silicon、macOS 26.6.2（25G83）、Xcode 26.6（17F113）、Swift 6.3.3 | 本機 `sw_vers`／`xcodebuild -version`／`swift --version` |
| CI runner | `macos-15` | `.github/workflows/ci.yml` |
| Xcode 專案 | 不需要；App 是 SwiftPM executable | ADR-011（含 2026-09-02 Amendment） |

## 2. 版本號 checklist

`scripts/make-app-bundle.sh` 以下列 regex 從 `CHANGELOG.md` 取版本，**取第一個相符的標題**：

```bash
sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | head -1
```

pattern 要求第一個字元是數字，所以 `## [Unreleased]` **不**相符；取不到時 fallback 為 `0.0.0`。同一個值同時寫進 `CFBundleShortVersionString` 與 `CFBundleVersion`。

發版順序：

1. 在 `CHANGELOG.md` 的 `## [Unreleased]` **下方**插入 `## [x.y.z] - YYYY-MM-DD`，把該版內容從 Unreleased 移下來，Unreleased 留空節。
2. 確認 `scripts/make-app-bundle.sh release` 輸出行尾的 `(version x.y.z, release)` 是預期版本 —— 這是唯一的版本驗證點，沒有第二處需要手改。
3. `plutil -p build/Threshold.app/Contents/Info.plist` 覆核 `CFBundleShortVersionString`。
4. 版本號規則見 `CHANGELOG.md` 開頭：Keep a Changelog + SemVer。

`THRESHOLD_BUNDLE_ID` 環境變數可覆寫 bundle identifier，預設 `dev.threshold.app`。**正式散布前必須改成實際擁有的 identifier**，因為它同時決定 TCC（藍牙授權）與 `SMAppService.mainApp`（Login Item）的身分。

## 3. 本機／CI 驗證（可完整執行）

依序執行，任一步非零結束即中止：

```bash
scripts/check-boundaries.sh
swift build
swift test
scripts/make-app-bundle.sh release
swift build --package-path Tools/rssi-record
```

| 指令 | 檢查什麼 | 2026-09-02 於本機的實際結果 |
|---|---|---|
| `scripts/check-boundaries.sh` | ADR-001／003／004 與 architecture.md §2 的六類邊界（Domain 不 import、無 private framework、無憑證處理／keystroke 合成、未文件化訊號只在 System、Domain 不讀時鐘、fixtures 匿名） | `boundaries OK` |
| `swift build` | 全 target 編譯與連結 | `Build complete!` |
| `swift test` | 全部測試 | `577 tests in 85 suites passed`（2026-09-03） |
| `scripts/make-app-bundle.sh release` | 組出 `build/Threshold.app`，並以 `plutil -lint` 驗證 Info.plist | `bundled: …/build/Threshold.app (version 0.0.0, release)` |
| `swift build --package-path Tools/rssi-record` | MVP 1B field recorder 仍能對 production scanner 建置 | `Build complete!` |

CI 跑的是同一組（`.github/workflows/ci.yml`），差別只有 bundle 用 `debug`。

`make-app-bundle.sh` 只刪除它自己產生的 `$out/Threshold.app`，不碰 `$out` 以外的路徑；簽章與 notarization 完全不在這支 script 裡（它不接觸任何憑證）。

## 4. EXTERNAL BLOCKER：簽章與 notarization

**狀態：阻擋中。** 本 repo 沒有、也不應有任何簽章憑證。以下步驟在憑證備妥前無法執行，也未曾被執行過，因此本節**沒有任何實測數據**。

### 4.1 需要的憑證與帳號

| 項目 | 用途 | 取得方式 |
|---|---|---|
| Apple Developer Program 會籍 | 取得 Developer ID 憑證的前提 | 付費會籍（個人或組織） |
| **Developer ID Application** 憑證（含私鑰，在 login keychain） | 簽 `Threshold.app` 與 `.dmg`，供 Mac App Store 以外散布 | Developer 帳號簽發，匯入本機 keychain |
| **Team ID**（10 碼） | `notarytool` 與 `codesign` 的身分識別 | Apple Developer 帳號頁 |
| **App Store Connect API key**（Issuer ID + Key ID + `.p8`）**或** Apple ID + app-specific password | `xcrun notarytool` 認證 | App Store Connect；建議用 API key，可避免把 Apple ID 密碼放進 CI |

憑證與 key 一律不進版控。`notarytool` 的憑證建議一次存進 keychain profile：

```bash
xcrun notarytool store-credentials "threshold-notary" \
  --key /secure/path/AuthKey_<KEY_ID>.p8 \
  --key-id <KEY_ID> \
  --issuer <ISSUER_ID>
```

### 4.2 Hardened runtime 與 entitlements

**這個 App 不需要任何 entitlement。** 理由：

- App **未啟用 App Sandbox**。`com.apple.security.device.bluetooth` 是 **sandbox 專用**的 entitlement，只有 sandboxed App 才需要它來取得藍牙；非 sandbox App 的藍牙存取由 TCC 管，條件是 Info.plist 具備 `NSBluetoothAlwaysUsageDescription` —— `make-app-bundle.sh` 已經寫入。因此**不要**加這個 entitlement。
- 之所以不能 sandbox：`ThresholdSystem` 需要 sandbox 不允許的系統面。
  - IOKit display wrangler：`IORegistryEntryFromPath("IOService:/IOResources/IODisplayWrangler")` + `IORequestIdle`（`Sources/ThresholdSystem/Controllers/LockStrategies.swift`）。
  - CGSession 查詢：`CGSessionCopyCurrentDictionary()` 讀 `CGSSessionScreenIsLocked`（`Sources/ThresholdSystem/Providers/SystemSessionQuery.swift`）。
  - 另有 `IOPMAssertionDeclareUserActivity`（`Controllers/WakeControlling.swift`）、`IORegistryEntryCreateCFProperty` 讀 platform UUID（`Stores/MacIdentity.swift`）、`SMAppService.mainApp`（`Controllers/LoginItemControlling.swift`）。
- Hardened runtime 的預設限制（無 JIT、無 unsigned executable memory、無 DYLD 環境變數、無 library validation 例外）沒有一項被上述程式碼觸及，所以 `--options runtime` 不需要搭配 exception entitlement。

### 4.3 簽章

Bundle 內只有一個 Mach-O（`Contents/MacOS/ThresholdApp`），沒有內嵌 framework 或 helper，所以單次簽章即可：

```bash
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  build/Threshold.app

codesign --verify --strict --verbose=2 build/Threshold.app
codesign --display --entitlements - build/Threshold.app
```

若未來確實需要 entitlement，才加上 `--entitlements`：

```bash
codesign --force --timestamp --options runtime \
  --entitlements Resources/Threshold.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  build/Threshold.app
```

加任何一條 entitlement 前，先在本文件記下它對應哪一個 API 呼叫；`ThresholdSystem` 以外的 target 不應產生 entitlement 需求（architecture.md §2）。

### 4.4 Notarization

`notarytool` 不吃裸 `.app`，要先打包（`ditto` 保留簽章與 extended attributes；`zip` 不保證）：

```bash
ditto -c -k --keepParent build/Threshold.app build/Threshold.zip

xcrun notarytool submit build/Threshold.zip \
  --keychain-profile "threshold-notary" \
  --wait

xcrun stapler staple build/Threshold.app
xcrun stapler validate build/Threshold.app
```

失敗時取 log：

```bash
xcrun notarytool log <SUBMISSION_ID> --keychain-profile "threshold-notary"
```

`stapler` 蓋在 `.app` 上（不是 zip）；蓋章後要重新打包才能散布。

### 4.5 Gatekeeper 預期

以下是**預期**，未經實測（沒有憑證就跑不到）：

| 產物狀態 | 使用者首次開啟的預期 |
|---|---|
| 未簽章／ad-hoc 簽章（目前 `make-app-bundle.sh` 的輸出） | 從網路下載後被 Gatekeeper 阻擋；只能以「右鍵 → 打開」或清除 quarantine 屬性繞過。**不可作為散布產物** |
| 已簽 Developer ID + hardened runtime，但未 notarize | 仍被阻擋 |
| 已簽 + 已 notarize + 已 staple | 直接開啟，無警告；離線也可通過（staple 把票據放進 bundle） |

驗證指令（憑證備妥後執行）：

```bash
spctl --assess --type exec --verbose=4 build/Threshold.app
```

另外兩點在首次簽章後必須實測確認，本文件不預先斷言結果：

- TCC 的藍牙授權綁定簽章身分。更換簽章憑證或 bundle identifier 後，使用者是否需要重新授權，需實機確認。
- `SMAppService.mainApp`（Login Item，system-integration.md §6 列為選用權限）在已簽章 bundle 下的註冊行為，需實機確認。

### 4.6 DMG（由維護者執行）

**RUN BY MAINTAINER** —— 需要 4.1 的憑證，且產物是對外散布物：

```bash
hdiutil create -volname "Threshold" \
  -srcfolder build/Threshold.app \
  -ov -format UDZO \
  build/Threshold-<x.y.z>.dmg

codesign --force --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  build/Threshold-<x.y.z>.dmg

xcrun notarytool submit build/Threshold-<x.y.z>.dmg \
  --keychain-profile "threshold-notary" --wait
xcrun stapler staple build/Threshold-<x.y.z>.dmg
```

`.app` 與 `.dmg` 各自 notarize 一次：先做 4.3／4.4 讓 `.app` 帶票據，再打包 DMG 並對 DMG 重跑一次。

## 5. 發版前的文件檢查

| 檢查 | 依據 |
|---|---|
| README／onboarding／行銷用語對裝置一律用「已觀察」而非「已支援」 | ADR-009 的 `Evidence status 2026-09-02`；SPIKE-009 仍為 PARTIAL |
| 不宣稱可從 system sleep 喚醒 Mac | system-integration.md §4；SPIKE-003 的 system sleep 部分未測且產品語意定義為不可能 |
| SPIKE 文件無「未執行卻寫結果」 | `docs/spikes/README.md` |
| `CHANGELOG.md` 的該版標題日期正確 | 第 2 節 |
| 隱私聲明與實作一致（本機處理、無 telemetry、匯出去識別化） | ADR-007 |
