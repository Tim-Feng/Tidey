import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BridgeInstallTests(unittest.TestCase):
    def test_reinstall_preserves_operator_environment_in_both_services(self):
        with tempfile.TemporaryDirectory(prefix="tidey-install-test-") as tmp:
            root = Path(tmp).resolve()
            bins = root / "bin"
            bins.mkdir()
            codesign = bins / "codesign"
            codesign.write_text("#!/bin/sh\nexit 0\n")
            codesign.chmod(0o755)
            source = root / "candidate"
            source.write_bytes(b"fake-bridge")
            plists = root / "plists"
            plists.mkdir()
            labels = ("com.tidey.remote-bridge", "com.tidey.remote-bridge.cloudflared")
            for label in labels:
                (plists / f"{label}.plist").write_bytes(plistlib.dumps({
                    "Label": label, "EnvironmentVariables": {
                        "TIDEY_PUSH_RELAY_URL": "https://example.invalid/relay",
                        "TEST_OPERATOR_SETTING": "preserve-me"}}))
            env = dict(os.environ, PATH=f"{bins}:{os.environ['PATH']}",
                       INSTALL_DIR=str(root / "installed"), PLIST_DIR=str(plists),
                       LOG_DIR=str(root / "logs"), SOURCE_BINARY=str(source),
                       BUILD_BRIDGE="0", LOAD_SERVICE="0")
            result = subprocess.run(["bash", str(ROOT / "RemoteBridge/install.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            for label in labels:
                installed = plistlib.loads((plists / f"{label}.plist").read_bytes())
                self.assertEqual("https://example.invalid/relay",
                                 installed.get("EnvironmentVariables", {}).get("TIDEY_PUSH_RELAY_URL"),
                                 "reinstall removed the configured relay")
                self.assertEqual("preserve-me", installed["EnvironmentVariables"]["TEST_OPERATOR_SETTING"])


if __name__ == "__main__":
    unittest.main()
