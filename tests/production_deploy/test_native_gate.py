"""Native carrier support through the capture and validate registry gates.

Fixtures are production-shaped (list_panels summaries, runtime descriptors, registry records)
and drive capture_checkpoint.registry_gate / validate_runtime_state.registry_gate, the same
functions each helper's main runs. Only the process table and ps birth lookups are injected."""
import contextlib
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/production_deploy"))
import deploy_common as dc
import capture_checkpoint
import validate_runtime_state

OUT, CAND = "/rt/tmux-out.sock", "/rt/tmux-cand.sock"
CHECKS = str(ROOT.parent / "life-system/.skills/tidey-production-deploy/scripts/deployment_checks.py")
T_OLD_DAEMON, T_OLD_AGENT = "Thu Sep 24 07:00:00 2026", "Thu Sep 24 07:01:00 2026"
T_NEW_DAEMON, T_NEW_AGENT = "Thu Sep 24 09:00:00 2026", "Thu Sep 24 09:00:00 2026"  # same second allowed
# role: vendor, durable, tmux session, carrier, panel index, pane, pid
TMUX = {"a": ("codex", "dur-a", "ctl-a", "P-A", 0, "%1", 611),
        "b": ("claude", "dur-b", "ctl-b", "P-B", 1, "%2", 621),
        "o": ("codex", "dur-o", "other", "P-O", 2, "%3", 631)}
# native: raw registry fields (the durable comes from dc.durable_id_for), carrier, index
NATIVE = {"n1": ({"vendor": "codex", "runtime": "codex_app_server", "session_id": "sess-n1",
                  "thread_id": "thread-cur", "resume_thread_id": "thread-old"}, "thread-cur", "C-N1", 3),
          "n2": ({"vendor": "claude", "session_id": "sess-n2", "thread_id": "ignored"}, "sess-n2", "C-N2", 4)}
SPECS = {role: {"vendor": TMUX[role][0], "durable_id": TMUX[role][1], "session": TMUX[role][2],
                "workspace_id": "w1", "panel_id": TMUX[role][3]} for role in ("a", "b")}


def world(desc_sock, live_tmux, gen="old", natives=("n1", "n2"), tmux_roles=("a", "b", "o")):
    """desc_sock: session -> socket; live_tmux: role -> socket; gen: native generation."""
    new = gen == "new"
    daemon = 700 if new else 500
    table = {daemon: (1, "iTermServer"), 600: (1, "tmux"), 601: (1, "tmux")}
    starts = {daemon: T_NEW_DAEMON if new else T_OLD_DAEMON}
    panels, descriptors, records = [], [], []
    for role in tmux_roles:
        vendor, durable, session, carrier, index, pane, pid = TMUX[role]
        panels.append({"panel_id": carrier, "logical_kind": "ordinary_tmux_window", "panel_index": index})
        descriptors.append({"binding": {"workspace_id": "w1", "panel_id": carrier, "tmux_pane_id": pane},
                            "revision": 5, "descriptor": {
                                "kind": "agent", "restore_policy": "create",
                                "target": {"tmux_session": session, "socket_path": desc_sock.get(session, OUT)},
                                "topology": {"windows": [{"name": session, "panes": [
                                    {"launch": {"executable": vendor, "arguments": ["resume", durable]}}]}]}}})
        if role in live_tmux:
            table[pid - 1] = (600 if live_tmux[role] == OUT else 601, "zsh")
            table[pid] = (pid - 1, vendor)
            starts[pid] = T_OLD_AGENT
            records.append({"path": f"/reg/{role}.json", "vendor": vendor, "session_id": durable,
                            "durable_id": durable, "workspace_id": "w1", "panel_id": carrier,
                            "tmux_socket_path": live_tmux[role], "tmux_pane_id": pane, "pid": pid,
                            "live_fields": {"pid": True}})
    for offset, name in enumerate(natives):
        raw, durable, carrier, index = NATIVE[name]
        shell, agent = daemon + 10 * (offset + 1), daemon + 10 * (offset + 1) + 1
        instance = f"S{offset + 1}{'b' if new else ''}"
        logical = f"native-session:{carrier}:{instance}"
        table[shell], table[agent] = (daemon, "zsh"), (shell, raw["vendor"])
        starts[agent] = T_NEW_AGENT if new else T_OLD_AGENT
        panels.append({"panel_id": logical, "carrier_panel_id": carrier, "native_session_id": instance,
                       "logical_kind": "native_session", "panel_index": index, "effective_shell_pid": shell})
        item = {"binding": {"workspace_id": "w1", "panel_id": carrier}, "revision": 9 if new else 3,
                "descriptor": {"kind": "agent", "restore_policy": "direct_resume",
                               "agent": {"durable_resume_id": durable, "vendor": raw["vendor"],
                                         "launch": {"executable": raw["vendor"], "arguments": ["resume", durable],
                                                    "cwd": "/project"}}}}
        if new:
            item["awaiting_runtime_evidence"] = True  # transient; excluded from the stable projection
        descriptors.append(item)
        record = {"path": f"/reg/{name}.json", "workspace_id": "w1",
                  # both on-disk forms exist in production: logical id and bare carrier id
                  "panel_id": logical if name == "n1" else carrier,
                  "tmux_socket_path": None, "tmux_pane_id": None, "pid": agent,
                  "live_fields": {"pid": True}, **raw}
        record["durable_id"] = dc.durable_id_for(record)
        records.append(record)
    snapshot = {"workspaces": {"result": {"workspaces": [{"workspace_id": "w1"}]}},
                "panels": {"w1": {"result": {"panels": panels}}},
                "runtime_resume_descriptors": {"result": {"descriptors": descriptors}}}
    return {"snapshot": snapshot, "records": records, "table": table, "starts": starts, "daemon": daemon}


def all_on(sock):
    return {TMUX[r][2]: sock for r in TMUX}


PHASES = {  # mode/kind -> (descriptor sockets, live tmux writers, native generation)
    "preinstall": (all_on(OUT), {"a": OUT, "b": OUT, "o": OUT}, "old"),
    "installed-pre-new-server": (all_on(OUT), {"a": OUT, "b": OUT, "o": OUT}, "old"),
    "new-server-pre-stage": (all_on(OUT), {"a": OUT, "b": OUT, "o": OUT}, "old"),
    "phase1-pre": ({**all_on(OUT), "ctl-b": CAND}, {"a": OUT, "o": OUT}, "old"),
    "phase1-post": ({**all_on(OUT), "ctl-b": CAND}, {"a": OUT, "o": OUT, "b": CAND}, "new"),
    "phase2-pre": (all_on(CAND), {"b": CAND}, "new"),
    "phase2-post": (all_on(CAND), {"a": CAND, "b": CAND, "o": CAND}, "new"),
    "post-retirement": (all_on(CAND), {"a": CAND, "b": CAND, "o": CAND}, "new"),
    "b-only": ({**all_on(OUT), "ctl-b": CAND}, {"a": OUT, "b": OUT, "o": OUT}, "old"),
    "all-descriptors": (all_on(CAND), {"a": OUT, "o": OUT, "b": CAND}, "new"),
    "phase": (all_on(CAND), {"b": CAND}, "new"),
}


class Harness(unittest.TestCase):
    def setUp(self):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(dc, "CFG", {"checks_module": CHECKS}))
        stack.enter_context(patch.object(dc, "OUTGOING_SOCKET", Path(OUT)))
        stack.enter_context(patch.object(dc, "CANDIDATE_SOCKET", Path(CAND)))
        self.starts = {}
        stack.enter_context(patch.object(dc, "process_start", side_effect=lambda pid: self.starts.get(pid)))

    def capture(self, kind, w, baseline=None, specs=SPECS):
        self.starts = w["starts"]
        return capture_checkpoint.registry_gate(kind, w["snapshot"], w["records"], w["table"], w["daemon"],
                                                baseline, specs, OUT, CAND)

    def baseline(self, **kw):
        w = world(*PHASES["preinstall"], **kw)
        gate = self.capture("predeploy", w)
        self.assertEqual(gate["problems"], [])
        summary = json.loads(json.dumps({"kind": "predeploy", "native_writers": gate["native"]}))
        return (w["snapshot"], w["records"], summary)

    def validate(self, mode, w, base):
        self.starts = w["starts"]
        return validate_runtime_state.registry_gate(mode, base[0], base[1], base[2], w["snapshot"], w["records"],
                                                    w["table"], w["daemon"], SPECS["b"])["problems"]

    def assertProblem(self, problems, fragment):
        self.assertTrue(any(fragment in p for p in problems), f"{fragment!r} not in {problems}")


class NativeGateTests(Harness):
    def test_mixed_native_codex_and_claude_pass_every_validate_mode(self):
        base = self.baseline()
        self.assertEqual({w["durable_id"] for w in base[2]["native_writers"]}, {"thread-cur", "sess-n2"})
        for mode in validate_runtime_state.MODES:
            with self.subTest(mode=mode):
                self.assertEqual(self.validate(mode, world(*PHASES[mode]), base), [])

    def test_mixed_native_pass_every_capture_kind(self):
        base = self.baseline()
        for kind in ("b-only", "all-descriptors", "phase"):
            with self.subTest(kind=kind):
                self.assertEqual(self.capture(kind, world(*PHASES[kind]), base)["problems"], [])

    def test_tmux_only_still_passes(self):
        base = self.baseline(natives=())
        for mode in validate_runtime_state.MODES:
            with self.subTest(mode=mode):
                self.assertEqual(self.validate(mode, world(*PHASES[mode], natives=()), base), [])

    def test_fresh_restart_keeps_carrier_and_conversation_with_new_instance_and_pid(self):
        base = self.baseline()
        w = world(*PHASES["phase2-pre"])
        self.assertNotEqual(w["daemon"], 500)
        self.assertEqual(self.validate("phase2-pre", w, base), [])

    def test_real_carrier_change_fails(self):
        base = self.baseline()
        w = world(*PHASES["phase1-post"])
        for panel in w["snapshot"]["panels"]["w1"]["result"]["panels"]:
            if panel.get("carrier_panel_id") == "C-N1":
                panel.update(carrier_panel_id="C-N9", panel_id="native-session:C-N9:S1b")
        for item in w["snapshot"]["runtime_resume_descriptors"]["result"]["descriptors"]:
            if item["binding"]["panel_id"] == "C-N1":
                item["binding"]["panel_id"] = "C-N9"
        next(r for r in w["records"] if r["path"] == "/reg/n1.json")["panel_id"] = "C-N9"
        problems = self.validate("phase1-post", w, base)
        self.assertProblem(problems, "workspace/panel identity differs")
        self.assertProblem(problems, "native_carrier_changed")

    def test_fresh_native_older_than_daemon_fails(self):
        base = self.baseline()
        w = world(*PHASES["phase2-post"])
        w["starts"][711] = T_OLD_AGENT
        self.assertProblem(self.validate("phase2-post", w, base), "native_older_than_daemon")

    def test_fresh_native_not_under_current_daemon_fails(self):
        base = self.baseline()
        w = world(*PHASES["phase2-post"])
        w["table"][710] = (1, "zsh")  # shell reparented away from the daemon
        self.assertProblem(self.validate("phase2-post", w, base), "native_not_under_daemon")

    def test_attach_pid_reuse_or_new_generation_fails(self):
        base = self.baseline()
        w = world(*PHASES["new-server-pre-stage"])
        w["starts"][511] = "Thu Sep 24 08:00:00 2026"
        self.assertProblem(self.validate("new-server-pre-stage", w, base), "native_generation_changed_during_attach")

    def test_attach_rejects_fresh_native_generation(self):
        base = self.baseline()
        self.assertProblem(self.validate("phase1-pre", world(*PHASES["phase1-pre"][:2], "new"), base),
                           "native_generation_changed_during_attach")

    def test_unreadable_birth_is_not_absent_or_new(self):
        base = self.baseline()
        for mode in ("installed-pre-new-server", "phase2-pre"):
            w = world(*PHASES[mode])
            del w["starts"][w["daemon"] + 11]
            with self.subTest(mode=mode):
                self.assertProblem(self.validate(mode, w, base), "native_birth_unreadable")
        w = world(*PHASES["phase2-pre"])
        del w["starts"][700]
        self.assertProblem(self.validate("phase2-pre", w, base), "daemon_birth_unreadable")

    def test_old_checkpoint_without_native_evidence_is_typed(self):
        snapshot, records, summary = self.baseline()
        summary.pop("native_writers")
        self.assertProblem(self.validate("phase1-post", world(*PHASES["phase1-post"]), (snapshot, records, summary)),
                           "checkpoint_missing_native_generation")
        stored = json.loads(json.dumps(self.baseline()[2]))
        stored["native_writers"][0].pop("start")
        self.assertProblem(self.validate("phase1-pre", world(*PHASES["phase1-pre"]), (snapshot, records, stored)),
                           "checkpoint_missing_native_birth")

    def test_missing_native_writer_is_not_restored(self):
        base = self.baseline()
        self.assertProblem(self.validate("phase2-post", world(*PHASES["phase2-post"], natives=("n2",)), base),
                           "native_not_restored")

    def test_none_none_record_outside_native_ancestry_is_unresolved(self):
        # A Genesis-style record with missing tmux fields is not assumed native.
        w = world(*PHASES["preinstall"])
        other = next(r for r in w["records"] if r["path"] == "/reg/o.json")
        other.update(tmux_socket_path=None, tmux_pane_id=None)
        self.assertProblem(self.capture("predeploy", w)["problems"], "unresolved_transport")

    def test_partial_transport_is_rejected(self):
        w = world(*PHASES["preinstall"])
        next(r for r in w["records"] if r["path"] == "/reg/o.json")["tmux_pane_id"] = None
        self.assertProblem(self.capture("predeploy", w)["problems"], "partial_transport")

    def test_bad_identity_is_rejected(self):
        cases = {
            "native_identity_mismatch": lambda w: next(r for r in w["records"] if r["path"] == "/reg/n2.json").update(panel_id="C-OTHER"),
            "native_shell_pid_invalid": lambda w: w["snapshot"]["panels"]["w1"]["result"]["panels"][3].pop("effective_shell_pid"),
            "missing_native_descriptor": lambda w: w["snapshot"]["runtime_resume_descriptors"]["result"]["descriptors"].pop(3),
            "native_descriptor_mismatch": lambda w: w["snapshot"]["runtime_resume_descriptors"]["result"]["descriptors"][3]["descriptor"]["agent"].update(durable_resume_id="thread-old"),
            "duplicate durable": lambda w: w["records"].append(dict(w["records"][3], path="/reg/dup.json")),
            "invalid_durable": lambda w: next(r for r in w["records"] if r["path"] == "/reg/n1.json").update(durable_id=None),
            "tmux_descriptor_mismatch": lambda w: next(r for r in w["records"] if r["path"] == "/reg/o.json").update(durable_id="dur-x"),
        }
        for fragment, mutate in cases.items():
            w = world(*PHASES["preinstall"])
            mutate(w)
            with self.subTest(fragment=fragment):
                self.assertProblem(self.capture("predeploy", w)["problems"], fragment)

    def test_native_descriptor_without_registry_writer_blocks_baseline(self):
        # Coverage is anchored in the native descriptors, not only in records that were found.
        for missing in (("/reg/n1.json",), ("/reg/n1.json", "/reg/n2.json")):
            w = world(*PHASES["preinstall"])
            w["records"] = [r for r in w["records"] if r["path"] not in missing]
            with self.subTest(missing=missing):
                self.assertProblem(self.capture("predeploy", w)["problems"], "native_descriptor_without_writer")

    def test_native_descriptor_without_authoritative_panel_blocks_baseline(self):
        w = world(*PHASES["preinstall"])
        panels = w["snapshot"]["panels"]["w1"]["result"]["panels"]
        panels[:] = [p for p in panels if p.get("carrier_panel_id") != "C-N2"]
        w["records"] = [r for r in w["records"] if r["path"] != "/reg/n2.json"]
        self.assertProblem(self.capture("predeploy", w)["problems"], "native_descriptor_without_panel")

    def test_plain_native_shell_without_agent_descriptor_is_not_required(self):
        w = world(*PHASES["preinstall"])
        w["table"][590] = (500, "zsh")
        w["snapshot"]["panels"]["w1"]["result"]["panels"].append(
            {"panel_id": "native-session:C-SH:S9", "carrier_panel_id": "C-SH", "native_session_id": "S9",
             "logical_kind": "native_session", "panel_index": 5, "effective_shell_pid": 590})
        self.assertEqual(self.capture("predeploy", w)["problems"], [])

    def test_inconsistent_native_logical_id_is_rejected(self):
        w = world(*PHASES["preinstall"])
        w["snapshot"]["panels"]["w1"]["result"]["panels"][3]["native_session_id"] = "S-other"
        with self.assertRaises(dc.GateError):
            self.capture("predeploy", w)

    def test_native_controller_is_rejected_before_first_stop(self):
        specs = {**SPECS, "b": {"vendor": "codex", "durable_id": "thread-cur", "session": "none",
                                "workspace_id": "w1", "panel_id": "C-N1"}}
        problems = self.capture("predeploy", world(*PHASES["preinstall"]), specs=specs)["problems"]
        self.assertProblem(problems, "unsupported_native_controller")

    def test_native_only_parses_but_deployment_contract_is_unsupported(self):
        gate = self.capture("predeploy", world({}, {}, natives=("n1", "n2"), tmux_roles=()))
        self.assertEqual({w["durable_id"] for w in gate["native"]}, {"thread-cur", "sess-n2"})
        self.assertFalse([p for p in gate["problems"] if not ("controller" in p)], gate["problems"])
        self.assertProblem(gate["problems"], "missing controller descriptor")


class DurableAndProjectionTests(unittest.TestCase):
    def test_registry_inventory_follows_product_durable_rule(self):
        cases = {
            "cur.json": ({"vendor": "codex", "runtime": "codex_app_server", "session_id": "s",
                          "thread_id": "thread-cur", "resume_thread_id": "thread-old"}, "thread-cur"),
            "resume.json": ({"vendor": "codex", "runtime": "codex_app_server", "session_id": "s2",
                             "resume_thread_id": "thread-old"}, "thread-old"),
            "tui.json": ({"vendor": "codex", "session_id": "s3", "thread_id": "t3"}, "s3"),
            "claude.json": ({"vendor": "claude", "session_id": "s4", "resume_thread_id": "t4"}, "s4"),
            "empty.json": ({"vendor": "codex", "runtime": "codex_app_server", "session_id": "s5",
                            "thread_id": "", "resume_thread_id": "thread-old"}, None),
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root / "v").mkdir()
            for name, (item, _) in cases.items():
                (root / "v" / name).write_text(json.dumps(item), encoding="utf-8")
            with patch.object(dc, "process_alive", return_value=True):
                got = {Path(r["path"]).name: r["durable_id"] for r in dc.registry_inventory(root)}
        self.assertEqual(got, {name: expected for name, (_, expected) in cases.items()})

    def test_stable_projection_allows_transients_but_not_semantics(self):
        base = world(*PHASES["preinstall"])["snapshot"]
        fresh = world(*PHASES["phase2-post"])["snapshot"]
        self.assertEqual(dc.native_descriptor_problems(base, fresh), [])
        for label, mutate in {
            "revision regressed": lambda item: item.update(revision=1),
            "identity drift": lambda item: item["descriptor"]["agent"]["launch"].update(cwd="/elsewhere"),
            "identity drift ": lambda item: item["descriptor"].update(future_field=True),
            "identity drift  ": lambda item: item["binding"].update(extra="x"),
        }.items():
            cur = copy.deepcopy(fresh)
            mutate(cur["runtime_resume_descriptors"]["result"]["descriptors"][3])
            with self.subTest(label=label):
                self.assertTrue(any(label.strip() in p for p in dc.native_descriptor_problems(base, cur)))


if __name__ == "__main__":
    unittest.main()
