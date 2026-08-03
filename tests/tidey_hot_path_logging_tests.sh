#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_path="$repo_root/Sources/PseudoTerminal.m"

python3 - "$source_path" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
source = source_path.read_text()

method_start = source.index("- (void)ensureTideyWorkspacesInitialized {")
method_end = source.index("- (NSInteger)indexOfWorkspaceContainingPanel:", method_start)
method = source[method_start:method_end]

for logging_call in ("DLog(", "NSLog("):
    if logging_call in method:
        raise SystemExit(
            f"workspace initialization hot path still contains {logging_call}"
        )

summary_log = "emitted panel summary ordinary tmux metadata"
if summary_log in source:
    raise SystemExit("panel-summary read path still emits ordinary-tmux metadata logs")
PY

echo "tidey hot-path logging tests passed"
