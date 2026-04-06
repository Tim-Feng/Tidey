#!/usr/bin/env python3

import base64
import os
import subprocess
import sys
from typing import Optional

try:
    from nacl.signing import SigningKey
except ImportError:
    print("Error: PyNaCl is required. Install it with: python3 -m pip install pynacl", file=sys.stderr)
    sys.exit(1)


KEYCHAIN_SERVICE = "https://sparkle-project.org"
KEYCHAIN_ACCOUNT = "ed25519"


def usage() -> int:
    print(
        f"Usage: {os.path.basename(sys.argv[0])} [--plist <path-to-Info.plist>] <path-to-dmg>",
        file=sys.stderr,
    )
    return 1


def load_private_key() -> bytes:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("Error: security command not found", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        message = stderr or "failed to read Sparkle EdDSA key from Keychain"
        print(f"Error: {message}", file=sys.stderr)
        sys.exit(1)

    encoded_key = result.stdout.strip()
    try:
        key_data = base64.b64decode(encoded_key, validate=True)
    except Exception as exc:
        print(f"Error: invalid base64 key data from Keychain: {exc}", file=sys.stderr)
        sys.exit(1)

    if len(key_data) != 96:
        print(
            f"Error: expected 96 decoded key bytes from Keychain, got {len(key_data)}",
            file=sys.stderr,
        )
        sys.exit(1)

    stored_public = key_data[64:]
    signing_key = SigningKey(key_data[:32])
    reconstructed = bytes(signing_key.verify_key)
    if stored_public != reconstructed:
        print("Error: Sparkle keychain entry contains a mismatched public key", file=sys.stderr)
        sys.exit(1)

    return key_data[:64]


def verify_plist_key(public_key_bytes: bytes, plist_path: Optional[str] = None) -> None:
    if plist_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        plist_path = os.path.join(os.path.dirname(script_dir), "plists", "iTerm2.plist")

    try:
        result = subprocess.run(
            ["plutil", "-extract", "SUPublicEDKey", "raw", plist_path],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("Warning: plutil command not found; skipped SUPublicEDKey verification", file=sys.stderr)
        return
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        message = stderr or f"unable to read SUPublicEDKey from {plist_path}"
        print(f"Warning: {message}", file=sys.stderr)
        return

    encoded_public = result.stdout.strip()
    try:
        plist_public = base64.b64decode(encoded_public, validate=True)
    except Exception as exc:
        print(f"Warning: invalid SUPublicEDKey in {plist_path}: {exc}", file=sys.stderr)
        return

    if plist_public != public_key_bytes:
        print(
            f"Warning: SUPublicEDKey in {plist_path} does not match the Keychain Sparkle public key",
            file=sys.stderr,
        )


def sign_file(path: str, private_key: bytes) -> tuple[str, int]:
    try:
        with open(path, "rb") as handle:
            payload = handle.read()
    except OSError as exc:
        print(f"Error: unable to read DMG file: {exc}", file=sys.stderr)
        sys.exit(1)

    seed = private_key[:32]
    signing_key = SigningKey(seed)
    signature = signing_key.sign(payload).signature
    return base64.b64encode(signature).decode("ascii"), len(payload)


def main() -> int:
    args = sys.argv[1:]
    plist_path = None
    if len(args) == 3 and args[0] == "--plist":
        plist_path = args[1]
        dmg_path = args[2]
    elif len(args) == 1:
        dmg_path = args[0]
    else:
        return usage()

    if not os.path.isfile(dmg_path):
        print(f"Error: file not found: {dmg_path}", file=sys.stderr)
        return 1

    private_key = load_private_key()
    verify_plist_key(private_key[32:], plist_path)
    signature, file_size = sign_file(dmg_path, private_key)

    print(f'sparkle:edSignature="{signature}" length="{file_size}"')
    print(signature)
    return 0


if __name__ == "__main__":
    sys.exit(main())
