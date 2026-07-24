# Bridge — 大/stale codex rollout 處理 hardening

對應 TODO：
- `/Users/timfeng/GitHub/life-system/TODO.md` > 📋 Tidey > Tidey Remote / Audit > tailer-lifecycle hardening
- `/Users/timfeng/GitHub/life-system/TODO.md` > 📋 Tidey > Tidey Remote / Audit > runaway rollout 管理

來源：2026-06-18/19 session 實機 debug Remote stale panel 時連帶查到。RemoteBridge tail codex rollout jsonl 的 lifecycle 與大檔處理在長壽巨大 session 下會出問題。

---

## A. tailer-lifecycle hardening（建議 branch `fix/remote-bridge-tailer-lifecycle`，base = local master）

兩個互相放大的問題：

### A1. stale fd 不釋放
panel 退出、registry record 消失後，Bridge 沒可靠地 stop tail 該 rollout、close fd。實機：adbrewer-codex 退出後其 3GB rollout 仍被 Bridge（fd）握著，要重啟 Bridge 才釋放磁碟空間。

- 正確偵測點：`AgentSessionRegistryMonitor.scanRegistry()`（每 2s）→ `syncRecords(_:)`（ClaudeTranscriptSession.swift:1310）→ 不在 active set 的 session 應 `sessions.removeValue(...)?.stop()`（:1329）。不是 `CodexAppServerRegistryRuntimeSyncer`（那隻只管 app-server socket runtime）。
- 最可能 bug：`CodexTranscriptSession.stop()` 用 `queue.sync`，而 session queue 同時做 tailer bootstrap / 增量讀 / parse / backfill；卡在大檔讀取時 stop 等不到、fd 留著。

### A2. 大 rollout 整檔讀卡 session queue
Bridge (重)attach 大 rollout 時從頭整檔 bootstrap/backfill/parse。3GB 檔或 67MB compacted 巨行會把 session queue 卡住 → Bridge 停止 accept → Remote 卡在「讀取 bridge」（實機重現過：手機連不上）。

### 修法方向
- active record 一消失 → 必 stop tailer + close fd；stop 可觀測（log）、不被長 parse 擋住。
- 大 rollout：bootstrap/backfill 設上限、seek 到接近 EOF 再 tail；超大單行 / compacted 巨行跳過（parse 前 cheap prefix scan 跳 `"type":"compacted"`，JSONLFileTailer 加單行大小上限）。
- 測試：record 移除 → stop 被呼叫 + fd close（temp 檔測試）；大檔邊界 fixture（JSONLFileReader / tailer）。
- 完成跑 build.sh + 整包 ModernTests + RemoteBridge swift test，再 fast-forward 回 master。

---

## B. runaway rollout 管理

codex rollout jsonl 是 append-only event log，長壽 session 會長到 GB 級。實測 `019e4d58` 3GB 裡 96% 是 `compacted` 事件（60 筆、後期每筆約 67MB），不是正常對話量（對話/工具內容才約 4%）。codex 的 compaction 只縮 model active context、不縮 rollout 檔，反而 append 一份大 snapshot — 是檔案爆大的成因。codex CLI 0.139.0 沒有穩定的「active rollout 超大自動輪替」設定；`local_thread_store_compression` / rollout truncation 都還 under-development，不要綁。

### 要做的
- active rollout size watchdog：Bridge 已知 active rollout_path，掃大小，超門檻（250MB warn / 1GB high-risk）在 Tidey/Remote 提示「建議輪替 thread」。
- 死 rollout 自動清理：active set = registry active records + app-server/lsof 開啟中的 rollout；非 active、超門檻、超保留天數才 archive/壓縮/刪。判定要保守。
- workflow rotation（真正止血）：active thread 太大時讓 agent 產 handoff summary、起新 thread，不要 resume 舊的；舊 app-server/TUI 結束後再清舊檔。
- 追 codex upstream 的 compression / truncation，穩定再接。
