import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/production_deploy"))
# The adapter refuses any symlinked parent; macOS /var and /tmp are symlinks,
# so fixtures live under the resolved temporary directory.
TEMP_BASE = Path(tempfile.gettempdir()).resolve()
import install_bundled_bridge as bridge


class BridgeInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_BASE)
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = root / 'candidate'; self.source.write_bytes(b'verified-candidate')
        self.target = root / 'installed'; self.target.write_bytes(b'outgoing-bridge')
        self.evidence = root / 'evidence'
        self.source_hash = bridge.digest(self.source); self.target_hash = bridge.digest(self.target)
        self.commands = []

    def runner(self, command, **kwargs):
        self.assertEqual(command[:3], ['/usr/bin/codesign', '--verify', '--strict'])
        self.assertEqual(len(command), 4)
        self.assertIn(Path(command[3]).parent, [self.source.parent, self.target.parent])
        self.commands.append(command)
        return type('Result', (), dict(returncode=0, stdout='', stderr=''))()

    def run_phase(self, *options, runner=None):
        return bridge.main(['--source', str(self.source), '--target', str(self.target),
                            '--source-sha256', self.source_hash, '--target-sha256', self.target_hash,
                            '--evidence', str(self.evidence), *options], runner=runner or self.runner)

    def test_actual_entrypoint_preserves_bytes_old_open_inode_and_operator_plist(self):
        plist = self.target.parent / 'operator.plist'; plist.write_bytes(b'operator-settings')
        with self.target.open('rb') as outgoing:
            old_inode = self.target.stat().st_ino
            self.run_phase()
            self.assertEqual(self.source_hash, bridge.digest(self.target))
            self.assertNotEqual(old_inode, self.target.stat().st_ino)
            self.assertEqual(b'outgoing-bridge', outgoing.read())
        self.assertEqual(b'operator-settings', plist.read_bytes())
        self.assertEqual(self.source_hash, bridge.digest(self.source))
        self.assertTrue((self.evidence / 'raw.json').exists())
        self.assertTrue((self.evidence / 'verified.json').exists())
        self.assertFalse(any('--sign' in command for command in self.commands))

    def test_bad_hash_unsigned_or_symlink_target_never_replaces(self):
        for failure in ['source-hash', 'target-hash', 'signature', 'symlink']:
            with self.subTest(failure=failure):
                self.evidence = self.target.parent / failure
                original_source, original_target = self.source_hash, self.target_hash
                if failure == 'source-hash': self.source_hash = '0' * 64
                if failure == 'target-hash': self.target_hash = '0' * 64
                if failure == 'symlink':
                    self.target.rename(self.target.parent / 'real-target')
                    self.target.symlink_to(self.target.parent / 'real-target')
                runner = (lambda *a, **k: type('Result', (), dict(returncode=1, stdout='', stderr='invalid'))()) if failure == 'signature' else self.runner
                with self.assertRaises(bridge.GateError): self.run_phase(runner=runner)
                self.assertEqual(b'outgoing-bridge', self.target.read_bytes())
                self.source_hash, self.target_hash = original_source, original_target

    def test_dry_run_namespace_and_occupied_attempt_never_replay(self):
        self.run_phase('--dry-run')
        self.assertFalse(self.evidence.exists())
        self.assertEqual(self.target_hash, bridge.digest(self.target))
        self.run_phase()
        with self.assertRaises(bridge.GateError): self.run_phase()

    def test_race_after_staging_blocks_before_replacement(self):
        def raced(command, **kwargs):
            result = self.runner(command, **kwargs)
            if Path(command[3]) != self.source: self.target.write_bytes(b'new-owner')
            return result
        with self.assertRaises(bridge.GateError): self.run_phase(runner=raced)
        self.assertEqual(b'new-owner', self.target.read_bytes())
        self.assertFalse((self.evidence / 'verified.json').exists())

    def test_other_attempt_stage_residue_blocks_before_any_install(self):
        residue = self.target.with_name('.' + self.target.name + '.previous-attempt.stage')
        residue.write_bytes(b'failed-previous-stage')
        for options in [(), ('--dry-run',)]:
            with self.subTest(options=options):
                with self.assertRaisesRegex(bridge.GateError, 'stage residue'):
                    self.run_phase(*options)
                self.assertEqual(self.target_hash, bridge.digest(self.target))
                self.assertEqual(b'failed-previous-stage', residue.read_bytes())
                self.assertFalse(self.evidence.exists())
                self.assertFalse(self.evidence.with_name(self.evidence.name + '.dryrun').exists())
        self.assertEqual([], self.commands)

    def test_successful_atomic_replace_with_failed_postcheck_retains_raw_and_no_replay(self):
        import os
        real_replace = os.replace
        def replaced(*args):
            real_replace(*args)
            raise OSError('caller failed after replacement')
        with patch.object(bridge, 'replace', replaced, create=True):
            with self.assertRaises(bridge.GateError): self.run_phase()
        self.assertEqual(self.source_hash, bridge.digest(self.target))
        self.assertTrue((self.evidence / 'raw.json').exists())
        with self.assertRaises(bridge.GateError): self.run_phase()
