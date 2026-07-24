# Tidey CI test debt cleanup plan

狀態：交給 tidey-cc 執行。

這份文件是本次工作的執行 handoff。依 CLAUDE.md「不要把 AI 產生的 plan 納入 commit」規則，本檔留在本機供執行時參考；實作 commits 不要 stage 本檔，除非 Tim 另行指定。

## 目標與完成條件

完成時必須同時成立：

1. 原始碼與 workflow 都找不到 TIDEY_SKIP_CI_HANGING_TESTS 或 TEST_RUNNER_TIDEY_SKIP_CI_HANGING_TESTS。
2. 目前被 gate 擋住的 21 個 tests 全部重新進入 master CI。
3. expression family 在獨立 fresh CI audit 與完整 ModernTests 都通過。
4. Browser Page Saver 15 個 tests 在獨立 fresh CI audit 與完整 ModernTests 都通過。
5. 最終 cleanup SHA 的 xcode-tests 連續取得 3 個可採計的 fresh GitHub-hosted jobs。
6. preparation timeout 不再列入 retry allowlist；hang 由 per-test timeout、step timeout、xcresult 與 build log 回報。
7. docs/debug-lessons.md 寫入本次六條教訓；docs/release-process.md 改成候選 commit、artifact、tag、appcast 對齊的流程。

## 已確認的基準

- master 基準：87d456d5e，v0.5.2 tag：ae6510b88。
- 第一個真正全綠的 shipping-tree workflow：run 29212683099，xcode job 86702960462。
- 該 xcode job 約 8 分 10 秒；Run tests step 約 6 分 36 秒。
- preparation timeout 的根因修正：
  - 40a31f2cc 移除 ModernTests.xctestplan 的 Malloc diagnostics。
  - ae6510b88 在 unit tests 下跳過 shell integration modal。
- origin/ci-test 已和 master 分岔，不要把 cleanup branch 強推到 origin/ci-test。
- 既有無關工作樹必須保留：
  - dirty submodules/openssl
  - docs/bridge-rollout-tailer-hardening.md
  - docs/tidey-autosave-restore-design.md
  - tests/selection-color-picker.html

### Gate 的實際數量

原始碼現況是 6 個 XCTSkipIf 位置，共涵蓋 21 個 test methods。先前「15 個 gate」與「Browser 10 個 tests」的紀錄已過時，驗收以以下清單為準。

| 群組 | Gate 位置 | 涵蓋 tests |
| --- | --- | --- |
| Expression | ModernTests/ExpressionSystemIntegrationTests.swift | testConcurrentBinaryEvaluation |
| Expression | ModernTests/IndirectValueTests.swift | testArrayDereferenceWithFunctionCall |
| Expression | ModernTests/SubexpressionTests.swift | testBinaryAsyncWithFunctionCalls |
| Non-browser | ModernTests/PathTests.swift | testExistingFileActionRecoversHardWrappedIndentedAbsolutePathAfterNullPadding |
| Non-browser | ModernTests/PathTests.swift 的 CodexWrapperRegistryTests.setUpWithError | testCodexWrapperWritesRegistryUsingLauncherChildRollout、testCodexWrapperRewritesRegistryWhenLauncherChildRolloutChanges |
| Browser | ModernTests/iTermBrowserPageSaverTests.swift 的 setUpWithError | 該 class 的 15 個 test methods |

Browser Page Saver 的 15 個 methods：

- testBasicPageSaving
- testDOCTYPEPreservation
- testCSSInlining
- testResourceDownloading
- testLocalResourceReferences
- testOriginalPageRemainsIntact
- testEmptyPage
- testPageWithNoResources
- testPageWithFailedResources
- testComplexPageStructure
- testCSSWithMultipleUrlReferences
- testNestedResourceReferences
- testSavePerformance
- testInvalidSaveLocation
- testNetworkFailureHandling

## 執行原則

### Branch 與證據保存

1. 使用兩個 PR：
   - PR A：ci-workflow-hardening，只做 Phase 1 永久 workflow／policy 護欄。
   - PR B：ci-test-debt-cleanup，從 PR A 合併後的最新 origin/master 建立，執行 Phase 2–5。
2. workflow_dispatch 必須先存在於 default branch；因此 PR A 要先 merge，PR B 才能用 branch ref 手動產生三個 run_attempt 1 的 runs。
3. 不使用 origin/ci-test；不 force-push 已產生 CI 證據的 SHA。
4. 每次失敗保留該 SHA、run URL、job ID、xcresult artifact 與 build log，讀完 diagnostics／spindump 才修改。
5. 任何 test source、app launch path、test plan 或 audit harness 的行為改動，都會把該階段的 3-job 計數歸零。
6. 文件文字修正不影響前一階段的 test 證據；最終 cleanup SHA 仍要另做 3-job 驗證。

### Fresh CI job 的定義

可採計的樣本必須：

- 使用相同 head SHA。
- 是不同的 GitHub Actions run ID 與 xcode job ID，且 run_attempt 都是 1；GitHub-hosted macos-15 runner 每次重新配置。
- workflow 內沒有觸發 retry。若遇到 ibtoold retry，即使最後成功，該次不列入 3-job 樣本。
- xcodebuild exit 0，xcresult 的 total test count 大於 0。
- xcresult 逐一列出本階段預期 test identifiers，狀態為 Success，不接受 Skipped／Not Run。
- 有可下載的 xcresult artifact 與 build log。

每個需要三次抽樣的 SHA：

1. 凍結 cleanup branch head，不再 push。
2. 使用 workflow_dispatch 對同一 branch 連續觸發 3 個獨立 workflow runs。
3. 每次 dispatch 前後都核對 head SHA 沒變。
4. 記錄三個 run ID、job ID、runner ID（API 有提供時）、結論與 artifact URL。

GitHub Actions rerun 產生的 run_attempt 2／3、內層 for attempt retry、或修改後只 rerun 舊 run，都不算 fresh job。

## Phase 0 — 建立基準與 cleanup branch

### 修改檔案

無。

### 動作

1. 確認 HEAD、origin/master、工作樹與上述無關檔案。
2. 建立 PR A 的 ci-workflow-hardening branch。
3. 記錄 run 29212683099 的：
   - head SHA
   - xcode job ID
   - job／Run tests step 時間
   - test count 與 skipped tests
4. 用 rg 重新產生 gate inventory，確認仍是 6 個 gate sites／21 tests。

### 驗收條件

- PR A branch 基於最新 origin/master。
- 沒有修改、stage 或刪除無關工作樹。
- 基準紀錄包含 run URL 與 xcresult test summary。
- xcresult 的舊 gate skipped identifiers 必須和本文件的 21 個 methods 一致；若數量不同，先更新 inventory 與各階段預期 delta，再開始移除 gate。

### CI 驗證

本階段不新增 CI。

### 風險與回退

- 風險：從過期 master 或 origin/ci-test 開始，造成後續結果不可比較。
- 回退：刪除尚未 push 的 cleanup branch，從最新 origin/master 重建；不改動 master。

## Phase 1 — 永久 workflow 護欄與 skip gate 規範

### 修改檔案

- .github/workflows/test.yml
- CLAUDE.md

### 動作

#### 1. Retry 只保留已證明的 build infrastructure failure

從 grep allowlist 移除：

    The test runner timed out while preparing to run tests

保留目前三個 asset compiler／ibtoold fingerprints：

- CompileAssetCatalogVariant failed
- IBPlatformToolFailureException
- The tool closed the connection

同步改註解與錯誤訊息，明確寫成 asset compiler／ibtoold retry。test host preparation timeout、per-test timeout、assertion failure與 crash 都直接失敗，不重跑。

把最多 3 次縮成最多 2 次；retry 條件同時要求：

- test_count == 0
- build log 命中上述已知 fingerprint

只要已有 test method 執行，任何 timeout／failure 都直接保留 artifact 並失敗。

#### 2. 建立 timeout 層級

永久設定：

- per-test default allowance：180 秒。
- per-test maximum allowance：600 秒。
- Run tests step timeout-minutes：30。
- xcode-tests job timeout-minutes：45。

關係：

- 600 秒讓單一 hang 能產生 timeout diagnostics。
- 30 分鐘約為目前正常 Run tests step 的 4.5 倍，涵蓋 clean build、完整 suite、單一 600 秒 timeout 與必要的 host recovery。
- job 比 Run tests step 多 15 分鐘，留給 checkout、xcresult finalize 與 artifact upload。
- 不把 job timeout 當 test timeout；Run tests step 必須先結束，Upload test results 才能執行。

若後續正常 full-suite p95 超過 20 分鐘，先找變慢的 test；只有確認是合理工作量後才調整 step timeout。job timeout 必須始終比所有前置 steps 加 Run tests step 至少多 10 分鐘。

#### 3. 失敗時保留 diagnostics

不要在每輪 retry 開頭刪掉前一輪證據。每次 attempt 使用獨立路徑：

- TestResults-attempt-1.xcresult、TestResults-attempt-2.xcresult
- build-output-attempt-1.txt、build-output-attempt-2.txt

test_count_from_result 改為接受 xcresult path 參數。維持 Upload test results 的 if: always()，用 glob 上傳所有 attempt xcresults 與 logs。artifact name 要含 run ID、job 與 run attempt，retention 維持 7 天。Run tests step timeout 後，upload step 仍須有時間執行。

保留：

- set -o pipefail
- xcodebuild exit status
- test count 大於 0 guard

#### 4. 加入手動 fresh-run 入口

在 workflow triggers 加入 workflow_dispatch，不新增可注入任意 xcodebuild 參數的 input。Phase 2–4 用同一 branch ref 手動 dispatch 三次，取得不同 run IDs／run_attempt 1 的 fresh samples。

#### 5. 在 CLAUDE.md 的 Testing Policy 加入 skip gate 格式

未來每個 CI skip 必須：

- 使用單一 failure family 專用的環境變數，不可再用 TIDEY_SKIP_CI_HANGING_TESTS 這類共用 catch-all。
- 限定在單一 test method 或共享同一 setup／failure fingerprint 的 test class。
- 在 XCTSkipIf 前放固定欄位：

    CI-SKIP
    reason: 可觀察的症狀與 failure fingerprint
    artifact: run/job/xcresult artifact URL 或 ID
    remove_when: 可驗證的移除條件

- skip reason string 要包含 failure family，讓 xcresult 可搜尋。
- 新增或重新加入 skip gate 會削弱 master CI，必須先取得 Tim 明確同意。
- retry 不能代替 skip debt 紀錄，skip 也不能關閉 timeout／artifact upload。

### 驗收條件

- workflow allowlist 不含 preparation timeout，retry 上限為 2，且只接受 0 tests + 已知 fingerprint。
- Run tests step 為 30 分鐘，xcode-tests job 為 45 分鐘。
- Upload test results 使用 if: always()，同時上傳所有 attempt-specific xcresults 與 logs。
- workflow_dispatch 可在固定 branch ref 觸發，沒有任意 command input。
- CLAUDE.md 包含 reason／artifact／remove_when 格式與專用 gate 規則。
- git diff --check 通過。
- actionlint 通過；環境沒有 actionlint 時，以 GitHub Actions parse 成功作最終 YAML 驗證。

### CI 驗證

- push structural commit，跑一輪 PR workflow。
- 此時所有既有 gates 仍在；預期 full suite 綠燈，artifact 同時含 xcresult 與 build_output.txt。
- 下載 artifact，確認 xcresulttool 可讀取 summary。
- merge PR A，等 master integration workflow 綠燈；確認 workflow_dispatch 已可用。
- 從更新後的 origin/master 建立 PR B 的 ci-test-debt-cleanup branch。

### Commit 邊界

可合併成一個 structural commit：

    [STRUCTURAL] Bound Xcode tests and preserve CI diagnostics

### 風險與回退

- 風險：step timeout 設太短，正常慢機器被誤殺。
- 回退：先以 15 分鐘為單位提高 step timeout，job timeout同步保留至少 10–15 分鐘 upload reserve；不可移除 per-test timeout。
- 風險：job timeout 先於 upload step發生。
- 回退：提高 job timeout，不提高 per-test maximum。
- 風險：artifact glob 在 build 提前失敗時沒有 xcresult。
- 回退：保留 if-no-files-found: warn，attempt-specific build log 仍應上傳；不要因此移除 always()。

## Phase 2 — 第一批：移除非 Browser gates，獨立壓測 expression family

本批移除 5 個 gate sites，涵蓋 6 個 tests；其中 3 個是 expression family。

### 修改檔案

永久 behavioral 變更：

- ModernTests/ExpressionSystemIntegrationTests.swift
- ModernTests/IndirectValueTests.swift
- ModernTests/SubexpressionTests.swift
- ModernTests/PathTests.swift

暫時 structural audit：

- .github/workflows/test.yml

### 動作

#### 1. 先加入暫時的 xcode-debt-audit job

用獨立 macos-15 job，不和正式 xcode-tests 共用 timeout。這個 job：

1. checkout recursive submodules。
2. 選取 last-xcode-version 指定的 Xcode。
3. xcodebuild build-for-testing 一次。
4. 明確 unset TEST_RUNNER_TIDEY_SKIP_CI_HANGING_TESTS 與 TIDEY_SKIP_CI_HANGING_TESTS。
5. expression family 連續執行 5 輪，每輪產生獨立 xcresult：
   - ExpressionSystemIntegrationTests/testConcurrentBinaryEvaluation
   - IndirectValueTests/testArrayDereferenceWithFunctionCall
   - SubexpressionTests/testBinaryAsyncWithFunctionCalls
6. 其餘 3 個 tests 執行一輪：
   - PathTests/testExistingFileActionRecoversHardWrappedIndentedAbsolutePathAfterNullPadding
   - CodexWrapperRegistryTests/testCodexWrapperWritesRegistryUsingLauncherChildRollout
   - CodexWrapperRegistryTests/testCodexWrapperRewritesRegistryWhenLauncherChildRolloutChanges
7. audit test step timeout-minutes 設 25，audit job timeout-minutes 設 50。
8. if: always() 上傳所有 audit xcresults 與 logs。

audit 用 test-without-building，並沿用：

    -parallel-testing-enabled NO
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance 180
    -maximum-test-execution-time-allowance 600

暫時 audit job 只存在 cleanup branch；Phase 3 會改成 Browser audit，Phase 4 完全刪除。

#### 2. 移除第一批 XCTSkipIf

刪除上述 5 個 gate sites 與已過期的 hang 註解。原測試 assertion、expectation timeout 與 cleanup 保持不變。

### 本機驗證

依序執行：

~~~sh
tools/run_tests.expect ModernTests/ExpressionSystemIntegrationTests/testConcurrentBinaryEvaluation
tools/run_tests.expect ModernTests/IndirectValueTests/testArrayDereferenceWithFunctionCall
tools/run_tests.expect ModernTests/SubexpressionTests/testBinaryAsyncWithFunctionCalls
tools/run_tests.expect ModernTests/PathTests/testExistingFileActionRecoversHardWrappedIndentedAbsolutePathAfterNullPadding
tools/run_tests.expect ModernTests/CodexWrapperRegistryTests
~~~

### 驗收條件

- 5 個非 Browser gate sites 已刪除。
- 六個 tests 在本機通過。
- expression audit 每個 fresh job 執行 3 methods × 5 輪，全部 passed。
- non-expression audit 的 3 methods 全部 passed。
- 同一 workflow 的正式 full suite 通過；六個本批 identifiers 都是 Success。
- full-suite skipped identifiers 從基準少 6 個，只剩 Browser Page Saver 15 個仍因舊 gate skipped。
- 沒有 test host preparation timeout、per-test timeout、crash 或 spindump。

### CI 驗證

在 behavioral gate-removal SHA 上取得 3 個可採計的 fresh workflow samples：

- 3 個正式 xcode-tests jobs 都通過。
- 3 個 xcode-debt-audit jobs 都通過。
- 三次都使用同一 head SHA。
- 任何一輪 expression／non-expression audit 失敗都使該 SHA 不合格。

每次 code 或 audit command 修改後，3-job 計數重新開始。

### Commit 邊界與依賴

依 Tidy First 分成兩個 commits：

1. structural：加入暫時 non-browser audit job。
2. behavioral：移除第一批 gates。

behavioral commit 依賴 structural audit commit。不要和 Browser gate removal 合併，保留獨立回退能力。

### 風險與回退

- 風險：expression engine 仍有獨立 deadlock。
- 回退：保留失敗 SHA 與 spindump；revert behavioral gate-removal commit。不要把 preparation timeout加回 retry allowlist。
- 風險：Codex wrapper process／Path test 仍依賴 runner 環境。
- 回退：用 xcresult 與 process log 找出缺少的 binary、PATH、HOME 或 cleanup；若是一個 focused test-harness fix，修完後重跑本階段三次。
- 風險：暫時 audit job 本身寫錯，產生測試假陰性。
- 回退：先以 gate 尚未移除的 commit驗證 audit job確實能找到並執行六個 methods；xcresult method count不符就不進 behavioral commit。

### 需要 Tim 決定的情況

expression failure 若證明需要改產品 expression 語意、公開 API 或大範圍 concurrency architecture，先交付 spindump 與最小重現，由 Tim 決定是否擴大本次 scope。單純 test harness、run-loop cleanup 或明確 deadlock fix 不需再次詢問。

## Phase 3 — 第二批：移除 Browser Page Saver gate

本批移除 1 個 class-level gate，重新啟用 15 個 WKWebView tests。

### 修改檔案

永久 behavioral 變更：

- ModernTests/iTermBrowserPageSaverTests.swift

暫時 structural audit：

- .github/workflows/test.yml

### 動作

1. 把 Phase 2 的暫時 xcode-debt-audit job 改成 Browser audit。
2. build-for-testing 後，明確 unset 兩個 skip env。
3. 以 test-without-building 執行：

    -only-testing:ModernTests/iTermBrowserPageSaverTests

4. audit test step timeout-minutes 維持 25，job timeout-minutes 維持 50。
5. if: always() 上傳 BrowserPageSaverGateAudit.xcresult 與 log。
6. 刪除 iTermBrowserPageSaverTests.setUpWithError 裡的 XCTSkipIf 與過期 hang 註解；保留 testHelper 初始化與 teardown。

### 本機驗證

~~~sh
tools/run_tests.expect ModernTests/iTermBrowserPageSaverTests
~~~

### 驗收條件

- Browser class-level gate 已刪除。
- 本機 15 個 tests 全部通過。
- 每個 Browser audit xcresult 都顯示 15 passed、0 skipped、0 failed。
- 正式 full suite 同時通過，15 個 Browser identifiers 都是 Success，舊 gate造成的 skipped identifiers 從 15 降為 0。
- WKWebView／WebContent process 在 test 結束後可正常 teardown，沒有 host crash、timeout 或殘留造成後續 tests 失敗。

### CI 驗證

在 Browser behavioral SHA 上取得 3 個可採計的 fresh workflow samples：

- 3 個正式 xcode-tests jobs 都通過。
- 3 個 Browser xcode-debt-audit jobs 都通過。
- 三次使用同一 head SHA。
- full suite 與 audit 都必須實際執行 Browser tests；job conclusion 綠燈但 xcresult 顯示 skipped 不算。

### Commit 邊界與依賴

分成兩個 commits：

1. structural：把暫時 audit job 從 non-browser retarget 成 Browser。
2. behavioral：移除 Browser gate。

本階段依賴 Phase 2 三次 fresh CI 全部通過。

### 風險與回退

- 風險：WKWebView 在 GitHub runner 仍有獨立 WebContent process、sandbox、GPU、persistent data store、HTTP server 或 run-loop問題。
- 回退：
  1. 保留失敗 SHA 與 Browser audit artifact。
  2. 讀 spindump、WebKit process log 與失敗 method。
  3. 一個 focused test fixture／teardown fix 可直接做，修後把本階段 3-job 計數歸零。
  4. 不自動恢復共用 TIDEY_SKIP_CI_HANGING_TESTS。
- 若需要暫時保留 debt，只能恢復 Browser 專用 gate，並依 Phase 1 格式填 reason、artifact、remove_when。

### 需要 Tim 決定的情況

若 Browser failure 需要修改 shipping WebKit 行為、引入新的 CI service，或超過一個 focused test-harness commit，Tim 決定延長本次 scope，或暫留一個 Browser 專用且有移除條件的 gate。

## Phase 4 — 刪除 gate infrastructure，寫入 lessons 與 release 流程

Phase 2、3 都通過後才進行。

### 修改檔案

- .github/workflows/test.yml
- docs/debug-lessons.md
- docs/release-process.md

CLAUDE.md 的永久 skip policy 保留。

### 動作

#### 1. 完全刪除舊 gate infrastructure

- 從正式 xcodebuild command 移除 TEST_RUNNER_TIDEY_SKIP_CI_HANGING_TESTS=1。
- 刪除暫時 xcode-debt-audit job。
- 確認所有 test source 已無舊 XCTSkipIf 與 hang 註解。

以下搜尋必須零結果：

~~~sh
rg -n "TIDEY_SKIP_CI_HANGING_TESTS|TEST_RUNNER_TIDEY_SKIP_CI_HANGING_TESTS" \
  .github ModernTests iTerm2XCTests tests docs CLAUDE.md
~~~

#### 2. docs/debug-lessons.md 加入六條教訓

在 Testing 章節新增「CI hosted tests」小節：

1. Pipeline truth：xcodebuild 經 tee 時必須用 pipefail／保存 producer status，並驗 xcresult test count，避免假綠。
2. Test plan 是 runtime config：xctestplan env 會覆蓋 shell env；Malloc diagnostics 必須 opt-in，config diff 要獨立審查。
3. Hosted app launch path：unit tests 下不得排程 modal、TCC prompt、installer 或 first-run UI；guard 要放在排程前。
4. Hang diagnostics：先讀 xcresult diagnostics／spindump，再修改；execution allowance 要讓主執行緒 stack 能產生。
5. Retry 必須有非確定性證據：相同 phase／stack 的 timeout 直接失敗，不用 retry 掩蓋。
6. Release provenance：shipping code 變更後要重新 build／簽章／公證；tag、artifact、CI 必須對應同一 candidate SHA。

補證至少包含：

- 5897a021a
- 40a31f2cc
- ae6510b88
- runs 29197275492、29211477438、29212683099

本次是 focused lesson update，不更新「審閱 marker」；marker 只在完整 lesson-learned review 後移動。

#### 3. docs/release-process.md 改成候選 commit 流程

取代目前先 build、再 commit metadata/appcast 的過時順序。新流程：

1. 建立 release candidate metadata commit：
   - version.txt
   - plists/iTerm2.plist
   - README.md
   - 不含 docs/appcast.xml
2. 在 repo 外準備 release notes；release notes 不放進 candidate commit。
3. push candidate commit，讓同一 SHA 的 required CI 全綠。
4. 從乾淨 candidate tree 執行 tools/release.sh；build 前工作樹必須乾淨，build 後只允許預期的 Tidey.dmg 與 docs/appcast.xml 變動。
5. 驗證 app bundle／DMG codesign、staple、spctl、架構、minimum system、SHA256、Sparkle signature 與 notary submission。
6. vX.Y.Z tag 必須指向 candidate SHA；push tag 前再核對 git rev-parse。
7. 建立 draft GitHub Release，使用 --verify-tag，上傳 DMG。
8. 從 draft release asset 重新下載，驗證 size 與 SHA256 一致；驗證完成後才 publish。
9. release asset 公開後，才單獨 commit／push docs/appcast.xml。
10. 等 GitHub Pages 後驗公開 appcast URL 與 enclosure URL。
11. candidate CI 完成後，只要 shipping source、build setting、version metadata 或 bundled binary有任何修改，舊 artifact 作廢，回到步驟 1 重新 CI、build、簽章與公證。

release checklist 要記錄：

- candidate SHA
- tag SHA
- CI run／job
- DMG size、SHA256
- architecture、minimum system
- Sparkle signature
- notary submission ID／status
- public asset SHA 驗證

更新文件裡過時的 v0.2.5 範例與「appcast 和 metadata 同 commit」指令，避免下次照舊流程發布。

### 驗收條件

- rg 對舊 gate 名稱為零結果。
- workflow 沒有暫時 audit job，永久 timeout／artifact／retry 規則仍在。
- debug-lessons 六條都有 symptom、evidence、action；marker 未移動。
- release-process 明確寫 candidate SHA、artifact invalidation、tag 對齊與 asset 先於 appcast。
- git diff --check 通過。
- 無關工作樹沒有被 stage。

### CI 驗證

最終 structural/docs SHA 跑 3 個可採計的 fresh xcode-tests jobs：

- 相同 head SHA。
- 三個不同 workflow run IDs，run_attempt 都是 1。
- 三次 full suite 都通過。
- 三次都沒有 workflow 內 retry。
- xcresult 逐一確認 21 個原 gated identifiers 都是 Success，找不到舊 gate skip reason。
- artifacts 都可下載並讀取 summary。

Python job每次也必須通過。任何 workflow 或 test source 修改都使三次計數歸零。

### Commit 邊界

分成三個 structural commits，方便獨立 review 與回退：

1. [STRUCTURAL] Retire CI skip environment and audit job
   - 移除已無 consumer 的 workflow env／暫時 audit job。
2. [STRUCTURAL] Document hosted CI hang diagnostics
   - 只修改 docs/debug-lessons.md。
3. [STRUCTURAL] Align release process to candidate tree
   - 只修改 docs/release-process.md。

三個 commits 都完成後才凍結 final SHA、做三次 fresh full CI。不要把 Phase 2、3 的 behavioral gate removals squash 進這些 commits。

### 風險與回退

- 風險：刪除 env 後出現遺漏的 hidden consumer。
- 回退：以 rg 與 xcresult定位 consumer；修 source，不恢復 catch-all env。
- 風險：移除 audit job 後只剩 full suite，診斷粒度下降。
- 回退：audit job內容保留在 commit history；需要時在診斷 branch恢復，不留在 master。
- 風險：release 文件和 tools/release.sh 現況不一致。
- 回退：逐步對照 script輸出；文件不可承諾 script沒有執行的自動化，手動步驟要明標。

## Phase 5 — Merge 前總驗收

### 靜態檢查

~~~sh
git diff --check origin/master...HEAD
rg -n "TIDEY_SKIP_CI_HANGING_TESTS|TEST_RUNNER_TIDEY_SKIP_CI_HANGING_TESTS" \
  .github ModernTests iTerm2XCTests tests docs CLAUDE.md
git status --short
~~~

第二個命令預期 exit 1／零結果。

### CI 證據表

在 PR description 填入：

| 階段 | Head SHA | Full-suite job IDs | Audit job IDs | Artifact URLs | 結論 |
| --- | --- | --- | --- | --- | --- |
| Phase 2 non-browser/expression |  |  |  |  |  |
| Phase 3 Browser |  |  |  |  |  |
| Phase 4 final tree |  |  | 不適用 |  |  |

### Merge 條件

- Phase 2、3、4 各自的三次 fresh CI 都符合採計規則。
- 21 個原 gated tests 都有 xcresult passed 證據。
- 最終 tree 的舊 gate 搜尋為零。
- PR commits 保持 structural／behavioral 邊界。
- 不包含本 plan 與既有無關工作樹。

### Merge 後

master push workflow 再跑一次，作為 branch protection／merge integration check。這次不取代 merge 前的三次 final-tree samples。

## 順序與依賴摘要

1. Phase 0 baseline，無 commit。
2. PR A：Phase 1 permanent workflow／policy structural commit；PR CI、merge、master integration CI。
3. 從更新後 master 建立 PR B。
4. PR B：Phase 2 temporary non-browser audit structural commit。
5. Phase 2 non-browser gate removal behavioral commit；三次 fresh full + audit CI。
6. Phase 3 audit retarget structural commit。
7. Phase 3 Browser gate removal behavioral commit；三次 fresh full + audit CI。
8. Phase 4 workflow cleanup structural commit。
9. Phase 4 debug lessons structural commit。
10. Phase 4 release process structural commit；凍結 final SHA 後跑三次 fresh full CI。
11. Phase 5 merge PR B；master integration CI。

不可平行：

- Browser gate removal 依賴 non-browser 三次通過。
- 舊 env 與 audit job 刪除依賴兩批 gate 都已通過。
- 最終 docs 應使用實際 run IDs，依賴 CI 證據完成。

可平行：

- Phase 2 audit 跑 CI 時可先草擬 debug lessons 與 release-process diff，但不要 commit，直到實際 run IDs確定。
- Phase 3 CI 跑時可整理 final PR evidence table。

## 需要 Tim 決定的項目

開始執行前沒有待決事項；Tim 已裁決由 Codex 規劃、tidey-cc 實作。

只有以下 contingency 需要 Tim：

1. Expression failure證明要改產品語意、公開 API 或大範圍 concurrency architecture。
2. Browser failure需要 shipping WebKit 改動、新 CI service，或超過一個 focused test-harness commit。
3. 任一群組無法在合理 focused fix 後達成三次 fresh CI，需要決定延長本次 scope，或保留一個專用、具 artifact 與 remove_when 的 gate。

一般 test fixture、path、process cleanup、workflow 與文件修正都在已授權範圍內，不需要再次詢問。
