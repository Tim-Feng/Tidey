"""Offline deployment tests. Importing the tools must never inspect production."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_common():
    spec = importlib.util.spec_from_file_location(
        "deployment_primitives", ROOT / "tools/production_deploy/deploy_common.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ImportSeamTests(unittest.TestCase):
    def test_import_without_job_configuration_never_contacts_production(self):
        with patch("subprocess.run", side_effect=AssertionError("live command")), \
                patch("socket.socket", side_effect=AssertionError("live socket")):
            common = load_common()
        self.assertEqual({}, common.CFG)
        self.assertTrue(callable(common.configure))
        self.assertTrue(callable(common.socket_snapshot))

    def test_evidence_never_overwrites_an_existing_failure(self):
        common = load_common()
        with tempfile.TemporaryDirectory(prefix="tidey-evidence-test-") as tmp:
            root = Path(tmp).resolve()
            path = root / "failed.json"
            path.write_text("original failure")
            common.CFG = {"task_dir": str(root), "checkpoint_root": str(root),
                          "checks_module": str(ROOT.parent / "life-system/.skills/tidey-production-deploy/scripts/deployment_checks.py")}
            with self.assertRaises(FileExistsError):
                common.write_json(path, {"replacement": True})
            self.assertEqual("original failure", path.read_text())


if __name__ == "__main__":
    unittest.main()
