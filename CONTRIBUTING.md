# Contributing

- 授權：Apache-2.0。貢獻採 **DCO**：每個 commit 需 `Signed-off-by:`（`git commit -s`）。不需要 CLA。
- 商標：名稱與圖示受 TRADEMARK.md 保護；fork 可自由使用程式碼，不得以原名發佈。
- 安全問題請依 SECURITY.md 私下回報。
- 任何 task 的 Definition of Done：Implementation + Tests + Documentation + Diagnostics（若適用）+ No known security regression。
- 未文件化 API 只允許出現在 `ThresholdSystem`，且必須附 Fake 與 Spike。

## Development

**一個分支一個 worktree。** 主 checkout 留在 `main`，功能分支開在 `../threshold-wt-<name>`：

```bash
git worktree add ../threshold-wt-<name> -b feat/<name> main
```

平行進行的工作因此不會互相覆寫未提交的檔案，也不會有人在錯的分支上編輯。開始編輯前先確認 `git status --short --branch` 與目前所在目錄。

### 提交前必跑

```bash
scripts/check-boundaries.sh
swift build
swift test
scripts/make-app-bundle.sh debug     # 動到 App、Package.swift 或 bundle script 時
```

CI（`.github/workflows/ci.yml`）跑的是同一組，另加 `swift build --package-path Tools/rssi-record`。任一步非零結束即視為未通過。

### Fixtures 的隱私規則

`Tests/Fixtures/BLE/` 的檔案禁止含 UUID、MAC 位址、廣播名稱與 wall-clock 時間。`scripts/check-boundaries.sh` 會檢查，但這不是唯一防線 —— `Tools/rssi-record` 從設計上就不讓 identifier 與名稱抵達寫檔路徑。實機錄製的 fixture 一律經由該工具產生，不要手貼原始掃描輸出。

同一支 script 也檢查其餘五類邊界：Domain 不 import 其他 target、無 private framework、無憑證處理與 keystroke 合成、未文件化訊號只出現在 `ThresholdSystem`、Domain 不讀時鐘。

### Spike 文件規則

**沒有跑就沒有結果。** Status 停在 `NOT RUN` 直到有實驗紀錄，不得先寫預期結論。

有量測但成功條件未被完整驗證時，Status 為 `PARTIAL`，且文件內必須同時有：

- `## Evidence` —— 實際環境、工具、回合與數字，裝置一律以代號稱呼；
- 一份明確的「Not yet measured」清單，逐條對應該文件自己的實驗章節。

`GO / CONDITIONAL GO / NO-GO` 只有在成功條件被完整驗證後才能寫，並附證據。原始資料留在 `Tools/spikes/out/`（已 gitignore），文件中不得出現任何 identifier、裝置名稱或主機名稱。

### Commit trailers

每個 commit 需 DCO 簽署：

```bash
git commit -s
```

會加上 `Signed-off-by: Name <email>`。AI 協作的 commit 另加：

```text
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: <session URL>
```
