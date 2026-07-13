# Tidey Release Process

從 commit 到使用者裝上新版的完整流程。照這份走一次就能 ship。

最近一次實跑：v0.5.2（2026-07-13）。

## 必要前置（每台開發機一次）

### Developer ID 憑證

登入 keychain 必須有可用的 signing identity：

```
security find-identity -v -p codesigning
```

應該看到 `Developer ID Application: Hsueh Cheng Feng (4T64VW5B7M)`（含對應 private key）。

**沒有 identity 但 Keychain Access 看得到 cert**：表示只有 cert、缺 private key。從 `.p12` 備份匯回（雙擊 `.p12` 或 Keychain Access → Import）。

**連 cert 都沒有**：從 Apple Developer portal 或舊機備份重下 `.p12`。

### notarytool keychain profile

```
xcrun notarytool history --keychain-profile Tidey
```

應該回傳過去 submission 歷史。失敗時重建：

```
xcrun notarytool store-credentials Tidey \
  --apple-id fsjforever26@gmail.com \
  --team-id 4T64VW5B7M
```

會互動問 app-specific password（從 appleid.apple.com 生）。

### Apple Developer agreement

Apple 偶爾推新版法務同意書。`notarytool history` 若回 `403 required agreement is missing or has expired`，去 [developer.apple.com/account/](https://developer.apple.com/account/) 接受 pending agreement。接受後幾分鐘內 API 恢復。

## 釋出前檢查

- 工作樹乾淨（`git status`）：只允許既有無關的未追蹤項目
- HEAD 在 master，所有要納入 release 的 commit 已 push
- 沒有未收斂的 CI 紅燈

## 步驟（候選 commit 流程）

核心原則：**tag、DMG、CI 證據必須指向同一個 candidate SHA**。任何 shipping source、build 設定、版本 metadata 或 bundled binary 在 candidate 定案後有變動，舊 artifact 一律作廢，回到步驟 1。

### 1. 建立 release candidate metadata commit

```
echo -n "0.5.X" > version.txt
tools/build.sh   # 讓 build phase 把版本寫進 plists/iTerm2.plist
```

更新 `README.md` 的 `## Latest in X.Y.Z` 區塊與 Install 下載 URL。

```
git add version.txt plists/iTerm2.plist README.md
git commit -m "[STRUCTURAL] Update release metadata for vX.Y.Z"
```

**不含 `docs/appcast.xml`**——appcast 必須等 asset 公開後才能發布（步驟 8）。

版本判準：PATCH = bug fix / 內部基建；MINOR = 明確新面向產品能力。工程量不是判準，使用者外顯才是。

### 2. 準備 release notes（repo 外）

寫到 `/private/tmp/Tidey-vX.Y.Z-release-notes.md`，三段：What's New / Fixes / Internal，英文、**粗體 title** + em-dash。不放進 candidate commit。

### 3. push candidate、等同一 SHA 的 CI 全綠

```
git push origin master
gh run watch <run-id> --exit-status
```

CI 綠燈必須落在 candidate SHA 本身。

### 4. 從乾淨 candidate tree 跑 release.sh

```
tools/release.sh
```

build 前工作樹必須乾淨（無關項除外）；build 後只允許出現 `Tidey.dmg` 與 `docs/appcast.xml` 的變動。腳本依序：preflight → clean build → inside-out codesign → DMG → notarize → staple → Sparkle sign → 更新 appcast → spctl。

### 5. 驗證 artifact

- 輸出行 `Version: X.Y.Z (build X.Y.Z)`、`Minimum system version:` 符合預期
- `shasum -a 256 Tidey.dmg` 記下
- `lipo -archs`、staple、spctl 由腳本輸出確認

### 6. tag 指向 candidate SHA

```
git rev-parse HEAD    # 必須仍是 candidate SHA
git tag vX.Y.Z && git push origin vX.Y.Z
```

### 7. Draft release → 上傳 → 驗證 → publish

```
gh release create vX.Y.Z --draft --verify-tag \
  --title "Tidey X.Y.Z" --notes-file /private/tmp/Tidey-vX.Y.Z-release-notes.md
gh release upload vX.Y.Z Tidey.dmg
# 從 draft asset 重新下載，SHA256 必須與步驟 5 一致
gh release edit vX.Y.Z --draft=false
```

### 8. asset 公開後，才單獨 commit / push appcast

```
git add docs/appcast.xml
git commit -m "Update appcast for vX.Y.Z"
git push origin master
```

push 觸發 GitHub Pages 部署。**順序不可倒**：appcast 先公開而 asset 不存在，Sparkle 用戶會拉到 404。

### 9. 後驗

- `curl -s https://tim-feng.github.io/Tidey/appcast.xml | grep "Tidey X.Y.Z"`（Pages 部署 1-2 分鐘）
- 公開 URL 重新下載 DMG，SHA256 與本機一致

### Release checklist 記錄

每次 release 記下：candidate SHA、tag SHA（同一個）、CI run/job ID、DMG size 與 SHA256、architecture、minimum system version、Sparkle EdDSA signature、notary submission ID 與 status、公開 asset SHA 驗證結果。

## 驗證

- [ ] `gh release view v0.2.X` 顯示 draft=false、有 DMG asset
- [ ] `curl -sI https://tim-feng.github.io/Tidey/appcast.xml | head -1`（等 Pages deploy 完成，通常 1-2 分鐘）
- [ ] `xmllint --xpath '//item[last()]/title/text()' docs/appcast.xml` 顯示新版
- [ ] 本機裝上 DMG → 右鍵 → 開啟 → 跑一下確認沒炸（可選，release.sh 的 spctl --assess 已確認簽章）

### Remote Bridge fresh-install audit

Remote pairing 是 release blocker。每次 release 前用乾淨 macOS 使用者帳號驗一次，避免 Tidey Remote 使用者裝完 Mac app 後看不到 QR code。

建議固定建立第二個本機使用者帳號 `tidey-test`。在該帳號登入後驗：

1. 確認 fresh state：
   - `~/Library/Application Support/Tidey Remote Bridge/` 不存在，或先移到備份位置。
   - `~/Library/LaunchAgents/com.tidey.remote-bridge.plist` 不存在。
   - `~/Library/LaunchAgents/com.tidey.remote-bridge.cloudflared.plist` 不存在。
2. 安裝剛產出的 `Tidey.dmg`，把 Tidey 拖進 `/Applications`。
3. 啟動 Tidey，開 Settings → Remote。
4. 預期 Remote tab 先顯示 `Setting up Tidey Remote Bridge...`，10-20 秒內 QR code 出現。
5. 驗 LaunchAgent：
   - `launchctl print gui/$(id -u)/com.tidey.remote-bridge` 有 service。
   - `curl -fsS http://127.0.0.1:4817/admin/status` 回 200 JSON。
6. 用 iPhone Tidey Remote 掃 QR，配對成功，能進 workspace list。
7. Quit Tidey 後重開，Remote tab 仍能顯示 QR，Bridge 不需要手動 install。
8. 如果該機沒有 `cloudflared`，Remote tab 可顯示 LAN pairing 可用、Internet access degraded；這不是 blocker。Bridge auto-install 不能依賴 `cloudflared`。

任何一步失敗都不要 release。先修 Mac app bundle / installer / LaunchAgent，再重新產 DMG。

## 故障排除

- **`security find-identity` 在 agent sandbox 回 0 valid identities，但 Keychain Access 看得到**
  - Codex agent sandbox 的假陰性；用互動式 shell 再跑一次確認（見 `docs/debug-lessons.md`）
- **notarytool 403 required agreement**
  - Apple 法務同意書過期；去 developer.apple.com 接受
- **`xcodebuild` 找不到 project**
  - 確認在 `~/GitHub/Tidey` 根目錄跑 `tools/release.sh`，不是 `tools/` 底下
- **notarize 卡住超過 10 分鐘**
  - 正常情況 2-5 分鐘。超過 10 分鐘可 `xcrun notarytool history --keychain-profile Tidey` 看最新 submission status。卡 `In Progress` 就繼續等，卡 `Invalid` 就看 `xcrun notarytool log <id> --keychain-profile Tidey` 看 Apple 回的具體錯誤
- **release.sh 中途失敗**
  - 已做的 notarize / sign 不用重來，但 DMG 要重新生。修根因後整個重跑 release.sh 最簡單

## 歷史參考

- v0.5.2（2026-07-13）：candidate/tag `ae6510b88`、DMG SHA256 `e4424d09…fec70d6e`、notary `2145bd34-c158-47c5-9321-896ceb205175`（首次因 unit-test guard 進 shipping code 而整包重建的案例）
- v0.2.5（2026-04-18）：commit `1b6cfe44f`、68 commits since v0.2.4
- v0.2.4（2026-04-09）：commit `5a413f1ab`
- 前幾版 release note 格式在 `gh -R Tim-Feng/Tidey release view v0.2.X`
