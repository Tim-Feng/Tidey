| type | test | seam | minimal change | commit kind | status |
| --- | --- | --- | --- | --- | --- |
| behavior | `TideyEditorFileTreeWatcherTests/testFileTreeReloadPreservesScrollPosition` | `tideyHandleEditorFileTreeRootDidChange` already owns the file-tree reload and state-restore path | snapshot file-tree scroll position before reload and restore it after the tree rebuild | BEHAVIORAL | pass |
| behavior | `TideyEditorFileTreeWatcherTests/testFileTreeReloadDoesNotReexpandSelectedCollapsedFolder` | the current root-change handler already snapshots expanded paths and selected path | restore selection without using the reveal path that auto-expands collapsed directories | BEHAVIORAL | pass |
