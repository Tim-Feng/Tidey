import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BundleSigningTests(unittest.TestCase):
    def test_signed_build_signs_copied_bridge_before_returning(self):
        with tempfile.TemporaryDirectory(prefix="tidey-bundle-test-") as tmp:
            root = Path(tmp)
            bins = root / "bin"
            bins.mkdir()
            swift = bins / "swift"
            swift.write_text("#!/bin/sh\nprintf 'Build complete\\n'\n")
            swift.chmod(0o755)
            codesign = bins / "codesign"
            codesign.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$SIGN_LOG"\n')
            codesign.chmod(0o755)
            scratch = root / "scratch"
            (scratch / "release").mkdir(parents=True)
            (scratch / "release/tidey-remote-bridge").write_bytes(b"test-bridge")
            (scratch / "release/tidey-remote-bridge").chmod(0o755)
            resources = root / "Resources/RemoteBridge"
            log = root / "sign.log"
            env = dict(os.environ, PATH=f"{bins}:{os.environ['PATH']}",
                       EXPANDED_CODE_SIGN_IDENTITY="test-developer-id",
                       CODE_SIGNING_ALLOWED="YES", SIGN_LOG=str(log),
                       TIDEY_REMOTE_BRIDGE_SCRATCH_PATH=str(scratch))
            result = subprocess.run(["bash", str(ROOT / "tools/bundle_remote_bridge.sh"),
                                     str(resources)], env=env, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertTrue(log.exists(), "signed App build left its bundled Bridge unsigned")
            self.assertEqual(["--force", "--options", "runtime", "--timestamp", "--sign",
                              "test-developer-id", str(resources / "tidey-remote-bridge")],
                             log.read_text().splitlines())
            log.unlink()
            for identity, allowed in (("", "YES"), ("-", "YES"),
                                      ("test-developer-id", "NO")):
                with self.subTest(identity=identity, allowed=allowed):
                    unsigned = dict(env, EXPANDED_CODE_SIGN_IDENTITY=identity,
                                    CODE_SIGNING_ALLOWED=allowed)
                    result = subprocess.run(
                        ["bash", str(ROOT / "tools/bundle_remote_bridge.sh"), str(resources)],
                        env=unsigned, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertFalse(log.exists(), "unsigned build invoked codesign")
            codesign.write_text("#!/bin/sh\nexit 17\n")
            failed = subprocess.run(
                ["bash", str(ROOT / "tools/bundle_remote_bridge.sh"), str(resources)],
                env=env, capture_output=True, text=True)
            self.assertEqual(17, failed.returncode, "signing failure must stop the build")


if __name__ == "__main__":
    unittest.main()
