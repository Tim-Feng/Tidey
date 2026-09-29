#!/usr/bin/env python3
"""Move runtime resume descriptors to the candidate socket, one accepted revision each.

usage: stage_descriptors.py --checkpoint <baseline-dir> --output <json> [--dry-run] <session> [session ...]

Only target.socket_path changes. Every other descriptor field and the binding must
remain byte-identical to the live pre-stage value; the accepted revision must be exactly
base+1. Sessions must currently point at the outgoing socket. Descriptor count and
session set are compared with the baseline checkpoint, not hardcoded.
"""
import argparse
import copy
import json
import time
from pathlib import Path

import deploy_common as dc


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("sessions", nargs="+")
    args = parser.parse_args(argv)
    dc.configure_file(args.config)
    OUT = Path(args.output)
    if args.dry_run:
        # dry-runs never occupy the real evidence name
        OUT = OUT.with_name(OUT.name[:-5] + ".dryrun.json" if OUT.name.endswith(".json") else OUT.name + ".dryrun.json")
    if OUT.exists() or OUT.is_symlink():
        dc.fail(f"output occupied: {OUT}")
    if len(args.sessions) != len(set(args.sessions)):
        dc.fail("duplicate requested session")
    baseline, _, summary = dc.load_checkpoint(args.checkpoint)
    _, _, baseline_by_session = dc.identity_sets(baseline)
    baseline_native, _ = dc.split_descriptors(baseline["runtime_resume_descriptors"]["result"]["descriptors"])
    if dc.tmux_server_pid(dc.CANDIDATE_SOCKET) is None:
        dc.fail("candidate server is not live; refuse to point descriptors at a missing server")


    def inventory():
        items = dc.request("list_runtime_resume_descriptors")["result"]["descriptors"]
        # Native direct_resume carriers have no tmux target. Staging only moves
        # tmux sockets, so native carriers are tracked separately and must stay unchanged.
        native, indexed = dc.split_descriptors(items)
        return indexed, items, native


    first, _, _ = inventory()
    time.sleep(0.35)
    second, before_items, before_native = inventory()
    if first != second or set(second) != set(baseline_by_session) or before_native != baseline_native:
        dc.fail("descriptor inventory unstable or differs from baseline session set")
    plan = []
    for session in args.sessions:
        current = second.get(session)
        if not current:
            dc.fail(f"missing descriptor: {session}")
        if current["descriptor"]["target"]["socket_path"] != str(dc.OUTGOING_SOCKET):
            dc.fail(f"descriptor is not on the outgoing socket: {session}")
        if current["binding"]["panel_id"] != baseline_by_session[session]["binding"]["panel_id"]:
            dc.fail(f"panel binding drift vs baseline: {session}")
        plan.append(session)

    if args.dry_run:
        dc.write_json(OUT, {"dry_run": True, "sessions": plan, "before": before_items})
        print(json.dumps({"dry_run": True, "would_stage": plan}))
        raise SystemExit(0)

    results = []
    for session in plan:
        current = second[session]
        base_revision = current["revision"]
        descriptor = copy.deepcopy(current["descriptor"])
        descriptor["target"]["socket_path"] = str(dc.CANDIDATE_SOCKET)
        response = dc.request("stage_runtime_resume_descriptor", {"binding": current["binding"], "descriptor": descriptor},
                              request_id_prefix="push-stage")
        result = response["result"]
        if result.get("accepted") is not True or result.get("changed") is not True or result.get("revision") != base_revision + 1:
            dc.write_json(OUT, {"sessions": plan, "before": before_items, "results": results, "failed": {"session": session, "response": response}})
            dc.fail(f"stage rejected or wrong revision for {session}: {response!r}")
        results.append({"session": session, "base_revision": base_revision, "accepted_revision": result["revision"],
                        "baseline": copy.deepcopy(current), "response": response})

    after_by_session, after_items, after_native = inventory()
    untouched = set(second) - set(plan)
    if (set(after_by_session) != set(second)
            or any(after_by_session[s] != second[s] for s in untouched)
            or after_native != before_native):
        dc.write_json(OUT, {"sessions": plan, "before": before_items,
                            "results": results, "after": after_items})
        dc.fail("an unselected descriptor changed during staging")
    for item in results:
        session = item["session"]
        after = after_by_session[session]
        expected = copy.deepcopy(item["baseline"]["descriptor"])
        expected["target"]["socket_path"] = str(dc.CANDIDATE_SOCKET)
        if after["descriptor"] != expected or after["binding"] != item["baseline"]["binding"] or after["revision"] != item["accepted_revision"]:
            dc.write_json(OUT, {"sessions": plan, "before": before_items, "results": results, "after": after_items})
            dc.fail(f"post-stage mismatch for {session}")
    dc.write_json(OUT, {"dry_run": False, "candidate_socket": str(dc.CANDIDATE_SOCKET), "sessions": plan,
                        "before": before_items, "results": results, "after": after_items})
    print(json.dumps({"staged": plan, "revisions": {r["session"]: r["accepted_revision"] for r in results}}))


if __name__ == "__main__":
    main()
