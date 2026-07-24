對應 TODO：/Users/timfeng/GitHub/life-system/TODO.md > Tidey > App 內建 autosave / restore

# Tidey App 內建 Autosave / Restore 設計

## 目標

Tidey Mac 直接保存與恢復目前使用者看到的 workspace / panel / tmux multi-window 狀態，不再依賴外部 `tidey-save` / `tidey-restore` 從 tmux、socket、pane option 反推 UI 狀態。

使用者語意很單純：

- `save`：保存目前 app 內存在的 workspace 與底下 panel；panel 底下如果有 tmux multi-window，也全部保存。
- `restore`：依照最後 snapshot 恢復 workspace、panel、tmux multi-window。
- save 當下不存在的 workspace / panel 就視為使用者不要了，不保留 disabled / missing 語意。

## Snapshot 內容

App 內建 snapshot 至少保存：

- workspace：id、title、排序、目前 selected workspace。
- panel：id、title、type、排序、workspace id、目前 selected panel。
- tmux-backed panel：target session、window list、active window、cwd、attach / restore command。
- agent panel：vendor、resume id、restore command、cwd。
- ordinary terminal panel：title、cwd、shell profile；不承諾恢復行程內部記憶體。

## Save 時機

不要只在 Cmd+Q / 關閉視窗時掃描完整狀態。正確流程是平常就維護 snapshot，退出時只 flush。

觸發點：

- workspace / panel 建立、刪除、改名、排序變更。
- panel focus / workspace focus 變更。
- tmux projection / multi-window 結構變更。
- agent resume id 或 restore command 更新。
- `applicationShouldTerminate:` / `applicationWillTerminate:`。
- 主視窗關閉流程。

實作上用 debounce autosave，退出時同步 flush。需要等待寫檔時可用 `NSTerminateLater`，寫完再允許 app 結束。

## Restore 流程

啟動 Tidey 時由 app 自己讀 snapshot 並建立 UI model：

1. 建立 workspace。
2. 建立 panel。
3. 對 tmux-backed panel attach 或重建 target session。
4. 投影 tmux windows。
5. 還原 selected workspace / selected panel。

restore 不應靠貼一整串 shell 指令進 PTY；這會被殘留輸入、shell prompt 狀態、paste timing 影響。

## 與外部工具的關係

`tidey-save` / `tidey-restore` 保留為 debug / migration / emergency 工具，不再是產品主路徑。

外部工具可以：

- 讀 app 內建 snapshot 做診斷。
- 手動匯出 / 匯入 snapshot。
- 在 app 無法啟動時做 emergency recovery。

外部工具不應再負責判斷目前 workspace / panel truth。

## 邊界

- `kill -9`、斷電、系統崩潰可能遺失最後幾秒狀態，因此需要平常 autosave。
- 非 tmux 的一般 shell 無法完整恢復正在跑的行程，只能恢復 panel、cwd、title、shell profile。
- tmux session 被使用者殺掉時，Tidey 只能依 snapshot 重建，不可能恢復已消失的行程記憶體。

## 驗收

- 建立 / 刪除 workspace 後重開 Tidey，結果完全反映最後狀態。
- 切換 workspace focus / panel focus 後重開 Tidey，focus 正確。
- 含 tmux multi-window 的 panel 重開後 windows、active window、panel 對應正確。
- Cmd+Q、關主視窗、正常重開都使用同一份 snapshot。
- 不需要手動跑 `tidey-save` / `tidey-restore` 也能恢復日常工作區。
