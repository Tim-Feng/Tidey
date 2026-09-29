#!/usr/bin/env python3
"""Render one installer template without discarding operator environment settings."""
import argparse
import os
from pathlib import Path
import plistlib
import stat
import tempfile


def render(template, existing, home, label):
    def expand(value):
        if isinstance(value, str):
            return value.replace("__HOME__", home).replace("__LABEL__", label)
        if isinstance(value, list):
            return [expand(v) for v in value]
        if isinstance(value, dict):
            return {k: expand(v) for k, v in value.items()}
        return value

    result = expand(template)
    if result.get("Label") != label or (existing and existing.get("Label") != label):
        raise ValueError("launch agent label mismatch")
    original = existing.get("EnvironmentVariables", {})
    defaults = result.get("EnvironmentVariables", {})
    for values in (original, defaults):
        if not isinstance(values, dict) or any(
                not isinstance(k, str) or not isinstance(v, str) for k, v in values.items()):
            raise ValueError("malformed launch agent environment")
    if original or defaults:
        result["EnvironmentVariables"] = {**defaults, **original}
    return result


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("template", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("home")
    parser.add_argument("label")
    args = parser.parse_args(argv)
    dest = args.destination
    if dest.is_symlink() or not dest.parent.is_dir():
        raise ValueError("launch agent destination missing or symlinked")
    existing = plistlib.loads(dest.read_bytes()) if dest.exists() else {}
    template = plistlib.loads(args.template.read_bytes())
    content = plistlib.dumps(render(template, existing, args.home, args.label))
    mode = stat.S_IMODE(dest.stat().st_mode) if dest.exists() else 0o644
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as handle:
            temporary = handle.name
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, dest)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


if __name__ == "__main__":
    main()
