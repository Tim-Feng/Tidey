from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/production_deploy"))
import deploy_common as dc


def tmux(carrier, session):
    return {"binding": {"workspace_id": "w1", "panel_id": carrier},
            "descriptor": {"kind": "agent", "restore_policy": "create",
                           "target": {"tmux_session": session, "socket_path": "/tmp/s.sock"},
                           "topology": {"windows": []}}}


def native(carrier, durable="d1"):
    # A direct_resume descriptor has no tmux target at all.
    return {"binding": {"workspace_id": "w1", "panel_id": carrier}, "revision": 1,
            "descriptor": {"kind": "agent", "restore_policy": "direct_resume",
                           "agent": {"durable_resume_id": durable, "vendor": "codex",
                                     "launch": {"executable": "codex", "arguments": ["resume", durable],
                                                "cwd": "/tmp"}}}}


def snapshot(descriptors):
    return {"workspaces": {"result": {"workspaces": [{"workspace_id": "w1"}]}},
            "panels": {"w1": {"result": {"panels": []}}},
            "runtime_resume_descriptors": {"result": {"descriptors": descriptors}}}


class NativeDescriptorTests(unittest.TestCase):
    def test_identity_sets_accepts_native_direct_resume_without_tmux_target(self):
        # Current production mixes tmux carriers with native direct_resume carriers.
        _, _, by_session = dc.identity_sets(snapshot([tmux("c-tmux", "genesis"), native("c-native")]))
        self.assertEqual(set(by_session), {"genesis"})

    def test_split_keeps_native_and_tmux_separate_and_never_drops_either(self):
        native_map, tmux_map = dc.split_descriptors([tmux("c-tmux", "genesis"), native("c-native")])
        self.assertEqual(set(native_map), {"c-native"})
        self.assertEqual(set(tmux_map), {"genesis"})

    def test_split_rejects_malformed_or_duplicate_descriptors(self):
        with_target = native("c-native")
        with_target["descriptor"]["target"] = {"tmux_session": "x"}
        for descriptors in ([with_target],
                            [native("c1"), native("c1", "d2")],
                            [tmux("c1", "s"), tmux("c2", "s")]):
            with self.subTest(descriptors=descriptors), self.assertRaises(dc.GateError):
                dc.split_descriptors(descriptors)

    def test_native_descriptor_drift_is_reported(self):
        before = snapshot([native("c-native", "d1")])
        self.assertEqual(dc.native_descriptor_problems(before, before), [])
        self.assertTrue(dc.native_descriptor_problems(before, snapshot([native("c-native", "d2")])))


if __name__ == "__main__":
    unittest.main()
