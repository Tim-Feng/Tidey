# Tidey Release Process

從 commit 到使用者裝上新版的完整流程。照這份走一次就能 ship。

最近一次實跑：v0.2.5（2026-04-18）。

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

- 工作樹乾淨（`git status`）：只允許 `RemoteBridge/.build/` 等既有未追蹤項目
- HEAD 在 master
- 所有要納入 release 的 commit 都已 push 到 origin 或本地 master
- 跑一次 `tools/build.sh` 確保 Deployment 前能編過（可選，release.sh 會自己清一次重建）

## 步驟

### 1. Bump version

```
echo -n "0.2.5" > version.txt
```

版本格式：`MAJOR.MINOR.PATCH`。判斷：

- PATCH（0.2.X）：bug fix / 內部基建 / 使用者外顯變化小
- MINOR（0.X.0）：明確新面向產品能力（新 UI、新模式、新整合）

工程量不是判準，使用者外顯才是。

`plists/iTerm2.plist` 的 `CFBundleShortVersionString` / `CFBundleGetInfoString` / `CFBundleVersion` 會由 Xcode build 期間的 `tools/updateVersion.py` 從 `version.txt` 讀取並寫入，**不用手動改**。

### 2. 跑 release.sh

```
cd ~/GitHub/Tidey
tools/release.sh
```

時間：5-15 分鐘（含 notarize 等待）。會依序做：

1. Preflight（驗 cert + notary profile）
2. `xcodebuild clean` + `tools/build.sh Deployment`
3. Inside-out codesign（所有 Mach-O / bundle / framework）
4. 打 DMG（含 `/Applications` symlink）
5. `notarytool submit --wait`
6. `stapler staple`
7. `sign_sparkle_update.py`（EdDSA）
8. 更新 `docs/appcast.xml`
9. `spctl --assess` 最終驗證

成功會印 `Done. DMG ready at: /Users/timfeng/GitHub/Tidey/Tidey.dmg`。

### 3. 更新 README

改 `README.md` 的 `## Latest in X.Y.Z` 區塊：

- 列 2-3 條最 user-visible 的亮點
- 英文、**粗體 title** + em-dash + 描述

改 Install 區塊的 `[Tidey.dmg](...v0.2.X/...)` URL 指向新版。

`docs/index.html` 不用動（下載連結用 `releases/latest/download`，自動跟上）。

### 4. Commit

```
git add version.txt plists/iTerm2.plist docs/appcast.xml README.md
git commit -m "[STRUCTURAL] Update appcast, README, and plist for v0.2.X"
```

commit 會同時包含：

- `version.txt`（手動 bump）
- `plists/iTerm2.plist`（build 自動寫入）
- `docs/appcast.xml`（release.sh 寫入）
- `README.md`（手動更新）

### 5. GitHub release

```
gh release create v0.2.X Tidey.dmg \
  --title "Tidey 0.2.X" \
  --notes "$(cat <<'EOF'
## What's New
- **Feature name** — user-facing description

## Fixes
- **Fix name** — what got fixed

## Internal
- **Refactor / infra summary** — implementation-level summary
EOF
)"
```

Release note 英文、三段分類：

- **What's New** — 使用者外顯的新功能
- **Fixes** — 修好的 bug
- **Internal** — 內部重構 / 基建（想讓讀的人知道就放，不然可以省）

分類依使用者可感知結果、不依工程量。

### 6. Push

```
git push origin master
```

觸發 GitHub Pages 部署 `docs/appcast.xml`。Sparkle auto-update 從此 URL 拉：
[https://tim-feng.github.io/Tidey/appcast.xml](https://tim-feng.github.io/Tidey/appcast.xml)

## 驗證

- [ ] `gh release view v0.2.X` 顯示 draft=false、有 DMG asset
- [ ] `curl -sI https://tim-feng.github.io/Tidey/appcast.xml | head -1`（等 Pages deploy 完成，通常 1-2 分鐘）
- [ ] `xmllint --xpath '//item[last()]/title/text()' docs/appcast.xml` 顯示新版
- [ ] 本機裝上 DMG → 右鍵 → 開啟 → 跑一下確認沒炸（可選，release.sh 的 spctl --assess 已確認簽章）

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

- v0.2.5（2026-04-18）：commit `1b6cfe44f`、68 commits since v0.2.4
- v0.2.4（2026-04-09）：commit `5a413f1ab`
- 前幾版 release note 格式在 `gh -R Tim-Feng/Tidey release view v0.2.X`
