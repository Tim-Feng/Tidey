import contextlib
import copy
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/production_deploy"))
import deploy_common as dc
import stage_descriptors


def fixture(native=False):
    # Production-shaped tmux carriers: the product always publishes kind,
    # restore_policy and topology alongside the target.
    descriptors = [{"descriptor": {"kind": "agent", "restore_policy": "create",
                                    "target": {"tmux_session": name, "socket_path": "/old.sock"},
                                    "topology": {"windows": []}, "cwd": "/project"}, "revision": 7,
                    "binding": {"panel_id": name, "workspace_id": "workspace"}}
                   for name in ("controller-a", "controller-b", "other")]
    if native:
        # A native direct_resume carrier has no tmux target; staging must leave it untouched.
        descriptors.append({"descriptor": {"kind": "agent", "restore_policy": "direct_resume",
                                           "agent": {"durable_resume_id": "thread-native", "vendor": "codex",
                                                     "launch": {"executable": "codex",
                                                                "arguments": ["resume", "thread-native"],
                                                                "cwd": "/project"}}},
                            "revision": 3, "binding": {"panel_id": "native-carrier", "workspace_id": "workspace"}})
    return {"workspaces": {"result": {"workspaces": [{"workspace_id": "workspace"}]}},
            "panels": {"workspace": {"result": {"panels": [
                {"panel_id": x["binding"]["panel_id"]} for x in descriptors]}}},
            "runtime_resume_descriptors": {"result": {"descriptors": descriptors}}}


class StageTests(unittest.TestCase):
    def exercise(self, fault=None, dry=False, native=False):
        with tempfile.TemporaryDirectory(prefix="tidey-stage-test-") as tmp:
            root = Path(tmp).resolve()
            output = root / "stage.json"
            baseline = fixture(native)
            live = copy.deepcopy(baseline["runtime_resume_descriptors"]["result"]["descriptors"])
            if fault == "native-drifted-before-stage":
                # The live native carrier already differs from the checkpoint baseline.
                next(x for x in live if x["binding"]["panel_id"] == "native-carrier")[
                    "descriptor"]["agent"]["durable_resume_id"] = "thread-drifted"
            writes = []

            def request(action, params=None, **kwargs):
                if action == "list_runtime_resume_descriptors":
                    return {"ok": True, "result": {"descriptors": copy.deepcopy(live)}}
                if action != "stage_runtime_resume_descriptor":
                    raise AssertionError("unregistered API")
                writes.append(copy.deepcopy(params))
                item = next(x for x in live if x["binding"] == params["binding"])
                item["descriptor"] = copy.deepcopy(params["descriptor"])
                item["revision"] += 1
                if fault == "other-descriptor-changed":
                    live[2]["descriptor"]["cwd"] = "/unexpected"
                if fault == "native-descriptor-changed":
                    native_item = next(x for x in live if x["binding"]["panel_id"] == "native-carrier")
                    native_item["descriptor"]["agent"]["durable_resume_id"] = "thread-other"
                response = {"ok": True, "result": {"accepted": True, "changed": True,
                                                    "revision": item["revision"]}}
                if fault == "revision-response":
                    response["result"]["revision"] -= 1
                return response

            config = {"task_dir": str(root), "checkpoint_root": str(root),
                      "checks_module": str(ROOT.parent / "life-system/.skills/tidey-production-deploy/scripts/deployment_checks.py")}
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(dc, "CFG", config))
                stack.enter_context(patch.object(dc, "OUTGOING_SOCKET", Path("/old.sock")))
                stack.enter_context(patch.object(dc, "CANDIDATE_SOCKET", Path("/new.sock")))
                stack.enter_context(patch.object(dc, "configure_file", return_value=None))
                stack.enter_context(patch.object(dc, "load_checkpoint", return_value=(baseline, [], {})))
                stack.enter_context(patch.object(dc, "tmux_server_pid", return_value=202))
                stack.enter_context(patch.object(dc, "request", side_effect=request))
                stack.enter_context(patch.object(dc, "run", side_effect=AssertionError("live command")))
                stack.enter_context(patch("socket.socket", side_effect=AssertionError("live socket")))
                stack.enter_context(patch.object(stage_descriptors.time, "sleep"))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                argv = ["--config", str(root / "config.json"), "--checkpoint", str(root),
                        "--output", str(output), "controller-b"]
                if dry:
                    argv.insert(0, "--dry-run")
                status = 0
                try:
                    stage_descriptors.main(argv)
                except SystemExit as error:
                    status = error.code
            return status, writes, {p.name: p.read_text() for p in root.glob("*.json")}, live

    def test_b_only_stage_preserves_all_other_descriptors(self):
        status, writes, files, live = self.exercise()
        self.assertEqual(0, status)
        self.assertEqual(["controller-b"], [x["descriptor"]["target"]["tmux_session"] for x in writes])
        self.assertEqual(["/old.sock", "/new.sock", "/old.sock"],
                         [x["descriptor"]["target"]["socket_path"] for x in live])
        self.assertIn("stage.json", files)

    def test_dry_run_cannot_stage_or_occupy_real_result(self):
        status, writes, files, _ = self.exercise(dry=True)
        self.assertEqual(0, status)
        self.assertEqual([], writes)
        self.assertNotIn("stage.json", files)
        self.assertIn("stage.dryrun.json", files)

    def test_wrong_revision_fails_and_preserves_response(self):
        status, writes, files, _ = self.exercise(fault="revision-response")
        self.assertEqual(1, status)
        self.assertEqual(1, len(writes))
        self.assertIn('"failed"', files["stage.json"])

    def test_concurrent_unrelated_descriptor_change_blocks(self):
        status, _, _, _ = self.exercise(fault="other-descriptor-changed")
        self.assertEqual(1, status, "stage ignored another descriptor changing during its API call")

    def test_stage_with_native_carrier_succeeds_and_leaves_it_unchanged(self):
        status, _, _, _ = self.exercise(native=True)
        self.assertEqual(0, status, "a native direct_resume carrier must not break tmux staging")

    def test_native_drift_from_baseline_blocks_before_any_stage_write(self):
        status, writes, _, _ = self.exercise(fault="native-drifted-before-stage", native=True)
        self.assertEqual(1, status, "stage started although a native carrier differs from the baseline")
        self.assertEqual([], writes, "no descriptor may be staged once native drift is observed")

    def test_native_carrier_change_during_stage_blocks(self):
        status, _, _, _ = self.exercise(fault="native-descriptor-changed", native=True)
        self.assertEqual(1, status, "stage ignored a native carrier changing during its API call")


if __name__ == "__main__":
    unittest.main()
