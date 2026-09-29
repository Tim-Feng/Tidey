"""Exact byte-preserving Bridge installation phase.

Installs the Developer ID signed Bridge that ships inside the production App
bundle. RemoteBridge/install.sh is the separate developer install: it builds from
source, ad-hoc re-signs by design and loads launchd services. Using it for a
signed bundle rewrites the signature, so the bundled and installed hashes differ.

The caller owns the full reviewed deployment gates. This helper never builds,
re-signs, rewrites launchd configuration, or restarts a service. A new explicit
evidence directory is required for each attempt; an occupied attempt is never
replayed. Commands are injectable for offline phase tests.
"""
import argparse
import hashlib
import json
import os
from os import replace
from pathlib import Path
import shutil
import subprocess

from deploy_common import GateError


def require(condition, reason):
    if not condition:
        raise GateError(reason)


def write_once(path, value):
    # Same contract as deployment_checks.write_evidence_once: exclusive creation
    # (an existing file or dangling symlink is refused), never an overwrite.
    content = json.dumps(value, indent=2, allow_nan=False) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def install(source, target, expected_source, expected_target, evidence, *, dry_run=False, runner=subprocess.run):
    def literal(path, *, existing=True):
        require(path.is_absolute() and not path.is_symlink()
                and not any(parent.is_symlink() for parent in path.parents), 'literal absolute path required')
        require(path.parent.is_dir(), 'parent missing')
        if existing: require(path.is_file(), 'regular binary required')

    def stamp(path):
        literal(path)
        value = path.stat()
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, digest(path))

    def verify(path):
        command = ['/usr/bin/codesign', '--verify', '--strict', str(path)]
        result = runner(command, capture_output=True, text=True)
        require(result.returncode == 0, 'Bridge signature validation failed')
        return {'command': command, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}

    if dry_run: evidence = evidence.with_name(evidence.name + '.dryrun')
    literal(source); literal(target); literal(evidence, existing=False)
    require(not evidence.exists(), 'attempt occupied; re-observe without replay')
    require(source != target and not source.samefile(target), 'source equals installed binary')
    stage_prefix = '.' + target.name + '.'
    require(not any(entry.name.startswith(stage_prefix) and entry.name.endswith('.stage')
                    for entry in target.parent.iterdir()),
            'stage residue requires explicit inspection; preserve previous attempt')
    source_stamp, target_stamp = stamp(source), stamp(target)
    require(source_stamp[-1] == expected_source and target_stamp[-1] == expected_target, 'binary hash changed')
    signature = verify(source)
    evidence.mkdir()
    write_once(evidence / 'intent.json', {'source': str(source), 'target': str(target),
               'source_stamp': source_stamp, 'target_stamp': target_stamp,
               'signature': signature, 'dry_run': dry_run})
    if dry_run: return {'status': 'dry-run-only'}
    stage = target.with_name('.' + target.name + '.' + evidence.name + '.stage')
    literal(stage, existing=False)
    require(not stage.exists(), 'stage occupied; preserve previous attempt')
    try:
        # New inode on the target filesystem; old running process mappings remain
        # intact after the atomic replacement. Do not re-sign bundled bytes.
        with stage.open('xb') as output, source.open('rb') as incoming:
            shutil.copyfileobj(incoming, output)
            output.flush(); os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o755)
        require(digest(stage) == expected_source, 'staged bytes differ from verified bundle')
        staged_signature = verify(stage)
        require(stamp(source) == source_stamp and stamp(target) == target_stamp, 'binary changed during staging')
        replace(stage, target)
    except Exception as error:
        write_once(evidence / 'raw.json', {'error': str(error), 'stage': str(stage),
                   'target_sha256': digest(target) if target.is_file() and not target.is_symlink() else None})
        raise GateError('installation outcome requires independent re-observation; do not replay') from error
    write_once(evidence / 'raw.json', {'replaced': True, 'stage_signature': staged_signature,
                                     'source_sha256': expected_source, 'target': str(target)})
    require(stamp(source) == source_stamp and digest(target) == expected_source, 'installed/bundled mismatch')
    installed_signature = verify(target)
    write_once(evidence / 'verified.json', {'target_sha256': digest(target),
                                          'signature': installed_signature, 'services_restarted': False})
    return {'status': 'binary-installed-only', 'services_restarted': False}


def main(argv=None, *, runner=subprocess.run):
    parser = argparse.ArgumentParser()
    for name in ['source', 'target', 'source-sha256', 'target-sha256', 'evidence']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    return install(Path(args.source), Path(args.target), args.source_sha256, args.target_sha256,
                   Path(args.evidence), dry_run=args.dry_run, runner=runner)


if __name__ == '__main__':
    main()
