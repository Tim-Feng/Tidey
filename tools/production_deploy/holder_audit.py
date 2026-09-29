#!/usr/bin/env python3
"""Inventory actual open-file holders (lsof, plus argv/cwd) and apply one gate.

usage: holder_audit.py <mode> --output <json> [--checkpoint <dir>] [--root <dir>] [--wait <seconds>]
modes:
  inventory              Diagnostics only; --root may override (default production bundle).
  production-prearchive  Tidey GUI is stopped. Only the lineage wrapper holders (bash fd255 on
                         Contents/Resources/bin/{claude,codex}) may remain and they must equal
                         the checkpoint's wrapper PID set. Ephemeral hook-dispatch holders are
                         waited for (--wait, default 60 s); any other holder (Tidey, pidinfo,
                         other) is reported and the gate fails. No PID allowlist.
  archive-transitional   New archive: wrapper holders ⊆ checkpoint wrapper set, no other holder;
                         every OLDER archive: zero holders.
  archive-final          Zero holders (lsof: cwd/txt/mapped/open) AND zero argv references under
                         the whole Deployment Backups root, excluding this audit process.
tccd holding an archive file is reported as STOP (exit 3, Tim decision). Roots are the exact
configured literal paths; --root is accepted only for inventory.
Exit codes: 0 pass, 1 gate failed, 3 tccd present.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import deploy_common as dc


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("mode", choices=["inventory", "production-prearchive", "archive-transitional", "archive-final"])
    parser.add_argument("--output", required=True)
    parser.add_argument("--checkpoint")
    parser.add_argument("--root")
    parser.add_argument("--wait", type=int, default=60)
    args = parser.parse_args(argv)
    dc.configure_file(args.config)
    OUT = Path(args.output)
    if OUT.exists() or OUT.is_symlink():
        dc.fail(f"output occupied: {OUT}")
    if args.root and args.mode != "inventory":
        dc.fail("--root is only allowed for inventory; gates use the configured literal roots")

    roots = {
        "inventory": [Path(args.root) if args.root else dc.PRODUCTION],
        "production-prearchive": [dc.PRODUCTION],
        "archive-transitional": sorted(p for p in dc.ARCHIVE_ROOT.glob("*.bundle-archive")),
        "archive-final": [dc.ARCHIVE_ROOT],
    }[args.mode]
    for root in roots:
        dc.literal_dir(root, "holder root")
    if args.mode == "archive-transitional" and dc.ARCHIVE not in roots:
        dc.fail(f"new archive missing: {dc.ARCHIVE}")

    expected_wrappers = None
    if args.mode in {"production-prearchive", "archive-transitional"}:
        if not args.checkpoint:
            dc.fail("--checkpoint required for this mode")
        _, _, summary = dc.load_checkpoint(args.checkpoint)
        expected_wrappers = set(summary["production_wrapper_holder_pids"])
        if not expected_wrappers:
            dc.fail("checkpoint has no wrapper holder inventory")


    def classify(record):
        if dc.is_wrapper_holder(record):
            return "wrapper"
        if dc.is_tccd_holder(record):
            return "tccd"
        if record.get("name", "").startswith(dc.PIDINFO_EXECUTABLE) or record.get("command") == "pidinfo":
            return "pidinfo"
        if record.get("command") == "Tidey":
            return "tidey-gui"
        return "other"


    deadline = time.monotonic() + max(0, args.wait)
    last = None
    while True:
        inventory = {}
        verdict, problems = "pass", []
        all_tccd = []
        for root in roots:
            holders = []
            for h in dc.lsof_holders(root):
                kind = classify(h)
                holders.append({**h, "kind": kind, "process_command": dc.process_command(h["pid"]), "process_start": dc.process_start(h["pid"])})
            argv = dc.argv_holders(root) if args.mode in {"archive-final", "inventory"} else []
            inventory[str(root)] = {"holders": holders, "argv_references": argv}
            wrappers = {h["pid"] for h in holders if h["kind"] == "wrapper"}
            tccd = [h for h in holders if h["kind"] == "tccd"]
            all_tccd.extend(tccd)
            others = [h for h in holders if h["kind"] not in {"wrapper", "tccd"}]
            describe = lambda items: [(h["pid"], h["kind"], h["command"], h["name"]) for h in items][:8]  # noqa: E731
            if args.mode == "production-prearchive":
                if others:
                    problems.append(f"non-wrapper holders still inside production: {describe(others)}")
                if wrappers != expected_wrappers:
                    problems.append(f"wrapper holder PIDs {sorted(wrappers)} != checkpoint {sorted(expected_wrappers)}")
            elif args.mode == "archive-transitional":
                if root == dc.ARCHIVE:
                    if others:
                        problems.append(f"unexpected non-wrapper holders in the new archive: {describe(others)}")
                    if not wrappers <= expected_wrappers:
                        problems.append(f"new-archive wrapper PIDs {sorted(wrappers - expected_wrappers)} not in checkpoint set")
                elif holders:
                    problems.append(f"older archive {root.name} has holders: {describe(holders)}")
            elif args.mode == "archive-final":
                if wrappers or others:
                    problems.append(f"archive holders remain: {describe([h for h in holders if h['kind'] != 'tccd'])}")
                if argv:
                    problems.append(f"processes still reference the archive root in argv: {argv[:6]}")
        if all_tccd:
            verdict = "stop-tccd"
        elif problems:
            verdict = "fail"
        last = {"mode": args.mode, "roots": [str(r) for r in roots], "verdict": verdict, "problems": problems,
                "inventory": inventory, "tccd": all_tccd,
                "expected_wrapper_pids": sorted(expected_wrappers) if expected_wrappers else None,
                "observed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
        if verdict != "fail" or args.mode == "inventory" or time.monotonic() >= deadline:
            break
        time.sleep(1.0)
    dc.write_json(OUT, last)
    print(json.dumps({k: last[k] for k in ("mode", "verdict", "problems")}, ensure_ascii=False))
    if last["verdict"] == "stop-tccd":
        print("STOP: tccd holds a file inside a deployment archive. Tim must dismiss the pending TCC dialog; "
              "do not probe, signal, or unregister anything.", file=sys.stderr)
        raise SystemExit(3)
    if last["verdict"] != "pass" and args.mode != "inventory":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
