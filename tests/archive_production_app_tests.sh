#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVER_UNDER_TEST="$SCRIPT_DIR/../tools/archive_production_app.sh"

python3 - "$ARCHIVER_UNDER_TEST" <<'PY'
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


archiver = Path(sys.argv[1]).resolve()


def make_app(root: Path, name: str = "Tidey.app", bundle_id: str = "com.tidey.app") -> Path:
    app = root / name
    info = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "Tidey"
    executable.parent.mkdir(parents=True)
    executable.write_text("candidate\n")
    info.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": "Tidey",
        "CFBundlePackageType": "APPL",
    }))
    return app


def make_lsregister(root: Path) -> tuple[Path, Path]:
    executable = root / "fake-lsregister"
    log = root / "lsregister.log"
    executable.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$@\" >> \"${FAKE_LSREGISTER_LOG:?}\"\n"
        "exit \"${FAKE_LSREGISTER_STATUS:-0}\"\n"
    )
    executable.chmod(0o755)
    return executable, log


def run_archiver(
    source: Path,
    backup_dir: Path,
    archive_name: str,
    lsregister: Path,
    log: Path,
    status: int = 0,
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["FAKE_LSREGISTER_LOG"] = str(log)
    environment["FAKE_LSREGISTER_STATUS"] = str(status)
    return subprocess.run(
        [
            str(archiver),
            "--source-app", str(source),
            "--backup-dir", str(backup_dir),
            "--archive-name", archive_name,
            "--lsregister", str(lsregister),
        ],
        text=True,
        capture_output=True,
        env=environment,
    )


with tempfile.TemporaryDirectory(prefix="tidey-archive-production-app-tests.") as temp:
    root = Path(temp)
    backup_dir = root / "Deployment Backups"
    backup_dir.mkdir()
    lsregister, log = make_lsregister(root)
    source = make_app(root)
    archive_name = "Tidey-production-before-test-20260821-210500.bundle-archive"

    result = run_archiver(source, backup_dir, archive_name, lsregister, log)
    archive = backup_dir / archive_name
    assert result.returncode == 0, result.stderr
    assert not source.exists()
    assert archive.is_dir()
    assert (archive / "Contents" / "MacOS" / "Tidey").read_text() == "candidate\n"
    assert log.read_text().splitlines() == ["-u", str(source)]
    assert str(archive) in result.stdout

with tempfile.TemporaryDirectory(prefix="tidey-archive-production-app-tests.") as temp:
    root = Path(temp)
    backup_dir = root / "Deployment Backups"
    backup_dir.mkdir()
    lsregister, log = make_lsregister(root)
    source = make_app(root)

    result = run_archiver(
        source,
        backup_dir,
        "Tidey.app-pre-test.bundle-archive",
        lsregister,
        log,
    )
    assert result.returncode != 0
    assert source.is_dir()
    assert not log.exists()
    assert "must not contain .app" in result.stderr

with tempfile.TemporaryDirectory(prefix="tidey-archive-production-app-tests.") as temp:
    root = Path(temp)
    backup_dir = root / "Deployment Backups"
    backup_dir.mkdir()
    lsregister, log = make_lsregister(root)
    source = make_app(root, bundle_id="com.example.other")

    result = run_archiver(
        source,
        backup_dir,
        "Tidey-production-before-test.bundle-archive",
        lsregister,
        log,
    )
    assert result.returncode != 0
    assert source.is_dir()
    assert not log.exists()
    assert "Unexpected bundle identifier" in result.stderr

with tempfile.TemporaryDirectory(prefix="tidey-archive-production-app-tests.") as temp:
    root = Path(temp)
    backup_dir = root / "Deployment Backups"
    backup_dir.mkdir()
    lsregister, log = make_lsregister(root)
    real_source = make_app(root, name="Real-Tidey.app")
    source = root / "Tidey.app"
    source.symlink_to(real_source, target_is_directory=True)

    result = run_archiver(
        source,
        backup_dir,
        "Tidey-production-before-test.bundle-archive",
        lsregister,
        log,
    )
    assert result.returncode != 0
    assert source.is_symlink()
    assert real_source.is_dir()
    assert not log.exists()
    assert "must not be a symbolic link" in result.stderr

with tempfile.TemporaryDirectory(prefix="tidey-archive-production-app-tests.") as temp:
    root = Path(temp)
    backup_dir = root / "Deployment Backups"
    backup_dir.mkdir()
    lsregister, log = make_lsregister(root)
    source = make_app(root)
    archive_name = "Tidey-production-before-test.bundle-archive"

    result = run_archiver(
        source,
        backup_dir,
        archive_name,
        lsregister,
        log,
        status=17,
    )
    assert result.returncode != 0
    assert source.is_dir()
    assert not (backup_dir / archive_name).exists()
    assert log.read_text().splitlines() == ["-u", str(source)]
    assert "LaunchServices unregister failed" in result.stderr

print("archive_production_app_tests: PASS")
PY
